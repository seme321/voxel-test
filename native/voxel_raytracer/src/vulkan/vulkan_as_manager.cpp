#include "vulkan_as_manager.h"
#include <godot_cpp/variant/utility_functions.hpp>
#include <cstring>
#include <algorithm>

namespace godot {

inline VkDeviceSize align_up(VkDeviceSize val, VkDeviceSize alignment) {
    return (val + alignment - 1) & ~(alignment - 1);
}

VulkanASManager::VulkanASManager() {}

VulkanASManager::~VulkanASManager() {
    cleanup();
}

bool VulkanASManager::init(VulkanContext* p_ctx) {
    ctx = p_ctx;
    if (!ctx || !ctx->device) {
        UtilityFunctions::printerr("[VulkanASManager] Invalid VulkanContext!");
        return false;
    }
    UtilityFunctions::print("[VulkanASManager] Initialized AS Manager for hardware ray tracing.");
    return true;
}

void VulkanASManager::cleanup() {
    if (!ctx || !ctx->device) return;

    // Wait idle before releasing resources
    if (ctx->vkDeviceWaitIdle) {
        ctx->vkDeviceWaitIdle(ctx->device);
    }

    // Destroy TLAS
    if (tlas != VK_NULL_HANDLE && ctx->vkDestroyAccelerationStructureKHR) {
        ctx->vkDestroyAccelerationStructureKHR(ctx->device, tlas, nullptr);
        tlas = VK_NULL_HANDLE;
    }
    destroy_buffer(tlas_buffer);
    destroy_buffer(tlas_instance_buffer);
    destroy_buffer(global_brick_buffer);
    destroy_buffer(scratch_buffer);
    current_scratch_size = 0;

    // Destroy all BLAS
    for (auto& pair : sectors) {
        SectorBLAS& s = pair.second;
        if (s.blas != VK_NULL_HANDLE && ctx->vkDestroyAccelerationStructureKHR) {
            ctx->vkDestroyAccelerationStructureKHR(ctx->device, s.blas, nullptr);
            s.blas = VK_NULL_HANDLE;
        }
        destroy_buffer(s.blas_buffer);
        destroy_buffer(s.aabb_buffer);
    }
    sectors.clear();
}

bool VulkanASManager::create_buffer(VkDeviceSize size, VkBufferUsageFlags usage, VkMemoryPropertyFlags mem_props, VulkanBuffer& out_buf) {
    if (!ctx || !ctx->device || size == 0) return false;

    // Always destroy prior buffer if any
    destroy_buffer(out_buf);

    VkBufferCreateInfo buf_info;
    memset(&buf_info, 0, sizeof(buf_info));
    buf_info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    buf_info.size = size;
    buf_info.usage = usage;
    buf_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

    if (ctx->vkCreateBuffer(ctx->device, &buf_info, nullptr, &out_buf.buffer) != VK_SUCCESS) {
        UtilityFunctions::printerr("[VulkanASManager] Failed to create VkBuffer of size: ", size);
        return false;
    }

    VkMemoryRequirements mem_reqs;
    ctx->vkGetBufferMemoryRequirements(ctx->device, out_buf.buffer, &mem_reqs);

    VkMemoryAllocateInfo alloc_info;
    memset(&alloc_info, 0, sizeof(alloc_info));
    alloc_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_reqs.size;
    alloc_info.memoryTypeIndex = ctx->find_memory_type(mem_reqs.memoryTypeBits, mem_props);

    VkMemoryAllocateFlagsInfo flags_info;
    memset(&flags_info, 0, sizeof(flags_info));
    if (usage & VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT) {
        flags_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO;
        flags_info.flags = VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT;
        alloc_info.pNext = &flags_info;
    }

    if (ctx->vkAllocateMemory(ctx->device, &alloc_info, nullptr, &out_buf.memory) != VK_SUCCESS) {
        UtilityFunctions::printerr("[VulkanASManager] Failed to allocate device memory for buffer!");
        ctx->vkDestroyBuffer(ctx->device, out_buf.buffer, nullptr);
        out_buf.buffer = VK_NULL_HANDLE;
        return false;
    }

    ctx->vkBindBufferMemory(ctx->device, out_buf.buffer, out_buf.memory, 0);
    out_buf.size = size;

    if (usage & VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT) {
        out_buf.device_address = ctx->get_buffer_address(out_buf.buffer);
    }

    if (mem_props & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) {
        ctx->vkMapMemory(ctx->device, out_buf.memory, 0, size, 0, &out_buf.mapped_ptr);
    }

    return true;
}

void VulkanASManager::destroy_buffer(VulkanBuffer& buf) {
    if (!ctx || !ctx->device) return;

    if (buf.mapped_ptr) {
        ctx->vkUnmapMemory(ctx->device, buf.memory);
        buf.mapped_ptr = nullptr;
    }
    if (buf.buffer != VK_NULL_HANDLE) {
        ctx->vkDestroyBuffer(ctx->device, buf.buffer, nullptr);
        buf.buffer = VK_NULL_HANDLE;
    }
    if (buf.memory != VK_NULL_HANDLE) {
        ctx->vkFreeMemory(ctx->device, buf.memory, nullptr);
        buf.memory = VK_NULL_HANDLE;
    }
    buf.size = 0;
    buf.device_address = 0;
}

VkCommandBuffer VulkanASManager::begin_single_time_commands() {
    VkCommandBufferAllocateInfo alloc_info;
    memset(&alloc_info, 0, sizeof(alloc_info));
    alloc_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    alloc_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    alloc_info.commandPool = ctx->command_pool;
    alloc_info.commandBufferCount = 1;

    VkCommandBuffer cmd = VK_NULL_HANDLE;
    ctx->vkAllocateCommandBuffers(ctx->device, &alloc_info, &cmd);

    VkCommandBufferBeginInfo begin_info;
    memset(&begin_info, 0, sizeof(begin_info));
    begin_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

    ctx->vkBeginCommandBuffer(cmd, &begin_info);
    return cmd;
}

void VulkanASManager::end_single_time_commands(VkCommandBuffer cmd) {
    ctx->vkEndCommandBuffer(cmd);

    VkSubmitInfo submit_info;
    memset(&submit_info, 0, sizeof(submit_info));
    submit_info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &cmd;

    ctx->vkQueueSubmit(ctx->queue, 1, &submit_info, VK_NULL_HANDLE);
    ctx->vkQueueWaitIdle(ctx->queue);

    ctx->vkFreeCommandBuffers(ctx->device, ctx->command_pool, 1, &cmd);
}

bool VulkanASManager::ensure_scratch_buffer(VkDeviceSize required_size) {
    VkDeviceSize aligned_size = align_up(required_size, 256);
    if (aligned_size <= current_scratch_size && scratch_buffer.buffer != VK_NULL_HANDLE) {
        return true;
    }

    destroy_buffer(scratch_buffer);
    if (!create_buffer(aligned_size,
                       VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
                       VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                       scratch_buffer)) {
        UtilityFunctions::printerr("[VulkanASManager] Failed to create scratch buffer of size: ", aligned_size);
        return false;
    }

    current_scratch_size = aligned_size;
    return true;
}

bool VulkanASManager::build_sector_blas(const Vector3i& p_pos,
                                       uint32_t p_aabb_count, const void* p_aabb_data,
                                       uint32_t p_brick_count, const void* p_brick_data) {
    if (p_aabb_count == 0 || !p_aabb_data) {
        remove_sector_blas(p_pos);
        return true;
    }

    int64_t key = get_sector_key(p_pos);
    SectorBLAS& sector = sectors[key];

    // If existing BLAS is present, clean it up before rebuild
    if (sector.blas != VK_NULL_HANDLE) {
        ctx->vkDestroyAccelerationStructureKHR(ctx->device, sector.blas, nullptr);
        sector.blas = VK_NULL_HANDLE;
    }
    destroy_buffer(sector.blas_buffer);
    destroy_buffer(sector.aabb_buffer);

    sector.sector_pos = p_pos;
    sector.aabb_count = p_aabb_count;
    sector.brick_count = p_brick_count;

    // Cache brick payload for global SSBO assembly
    if (p_brick_count > 0 && p_brick_data) {
        size_t brick_bytes = p_brick_count * 1096;
        sector.brick_data.resize(brick_bytes);
        memcpy(sector.brick_data.data(), p_brick_data, brick_bytes);
    } else {
        sector.brick_data.clear();
    }

    // 1. Upload AABB positions (24 bytes each: minX, minY, minZ, maxX, maxY, maxZ)
    VkDeviceSize aabb_size = p_aabb_count * 24;
    if (!create_buffer(aabb_size,
                       VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT_KHR | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                       sector.aabb_buffer)) {
        UtilityFunctions::printerr("[VulkanASManager] Failed to allocate AABB buffer for sector ", p_pos);
        return false;
    }
    memcpy(sector.aabb_buffer.mapped_ptr, p_aabb_data, aabb_size);

    // 2. Setup AABB Geometry description
    VkAccelerationStructureGeometryKHR geom;
    memset(&geom, 0, sizeof(geom));
    geom.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR;
    geom.geometryType = VK_GEOMETRY_TYPE_AABBS_KHR;
    geom.flags = VK_GEOMETRY_OPAQUE_BIT_KHR;
    geom.geometry.aabbs.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_AABBS_DATA_KHR;
    geom.geometry.aabbs.data.deviceAddress = sector.aabb_buffer.device_address;
    geom.geometry.aabbs.stride = 24;

    // 3. Query required build sizes
    VkAccelerationStructureBuildGeometryInfoKHR build_info;
    memset(&build_info, 0, sizeof(build_info));
    build_info.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR;
    build_info.type = VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR;
    build_info.flags = VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT_KHR;
    build_info.mode = VK_BUILD_ACCELERATION_STRUCTURE_MODE_BUILD_KHR;
    build_info.geometryCount = 1;
    build_info.pGeometries = &geom;

    uint32_t max_prim_count = p_aabb_count;
    VkAccelerationStructureBuildSizesInfoKHR size_info;
    memset(&size_info, 0, sizeof(size_info));
    size_info.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR;
    ctx->vkGetAccelerationStructureBuildSizesKHR(
        ctx->device,
        VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR,
        &build_info,
        &max_prim_count,
        &size_info
    );

    // 4. Ensure scratch buffer
    if (!ensure_scratch_buffer(size_info.buildScratchSize)) {
        return false;
    }

    // 5. Allocate BLAS storage buffer
    if (!create_buffer(size_info.accelerationStructureSize,
                       VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_STORAGE_BIT_KHR | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
                       VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                       sector.blas_buffer)) {
        UtilityFunctions::printerr("[VulkanASManager] Failed to allocate BLAS storage buffer!");
        return false;
    }

    // 6. Create BLAS acceleration structure handle
    VkAccelerationStructureCreateInfoKHR as_create_info;
    memset(&as_create_info, 0, sizeof(as_create_info));
    as_create_info.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_CREATE_INFO_KHR;
    as_create_info.buffer = sector.blas_buffer.buffer;
    as_create_info.offset = 0;
    as_create_info.size = size_info.accelerationStructureSize;
    as_create_info.type = VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR;

    if (ctx->vkCreateAccelerationStructureKHR(ctx->device, &as_create_info, nullptr, &sector.blas) != VK_SUCCESS) {
        UtilityFunctions::printerr("[VulkanASManager] Failed to create BLAS acceleration structure!");
        return false;
    }

    // 7. Retrieve BLAS Device Address
    VkAccelerationStructureDeviceAddressInfoKHR addr_info;
    memset(&addr_info, 0, sizeof(addr_info));
    addr_info.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_DEVICE_ADDRESS_INFO_KHR;
    addr_info.accelerationStructure = sector.blas;
    sector.blas_address = ctx->vkGetAccelerationStructureDeviceAddressKHR(ctx->device, &addr_info);

    // 8. Dispatch GPU command to build BLAS
    build_info.dstAccelerationStructure = sector.blas;
    build_info.scratchData.deviceAddress = scratch_buffer.device_address;

    VkAccelerationStructureBuildRangeInfoKHR range_info;
    memset(&range_info, 0, sizeof(range_info));
    range_info.primitiveCount = p_aabb_count;
    range_info.primitiveOffset = 0;
    range_info.firstVertex = 0;
    range_info.transformOffset = 0;

    const VkAccelerationStructureBuildRangeInfoKHR* p_range_infos = &range_info;

    VkCommandBuffer cmd = begin_single_time_commands();
    ctx->vkCmdBuildAccelerationStructuresKHR(cmd, 1, &build_info, &p_range_infos);

    // Memory barrier to make BLAS available for TLAS build
    VkMemoryBarrier barrier;
    memset(&barrier, 0, sizeof(barrier));
    barrier.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER;
    barrier.srcAccessMask = VK_ACCESS_ACCELERATION_STRUCTURE_WRITE_BIT_KHR;
    barrier.dstAccessMask = VK_ACCESS_ACCELERATION_STRUCTURE_READ_BIT_KHR;
    ctx->vkCmdPipelineBarrier(cmd,
                              VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,
                              VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,
                              0, 1, &barrier, 0, nullptr, 0, nullptr);

    end_single_time_commands(cmd);

    UtilityFunctions::print("[VulkanASManager] Built BLAS for sector (", p_pos.x, ",", p_pos.y, ",", p_pos.z,
                           ") with ", p_aabb_count, " bricks (Addr: 0x", String::num_uint64(sector.blas_address, 16), ")");
    return true;
}

void VulkanASManager::remove_sector_blas(const Vector3i& p_pos) {
    int64_t key = get_sector_key(p_pos);
    auto it = sectors.find(key);
    if (it == sectors.end()) return;

    SectorBLAS& s = it->second;
    if (s.blas != VK_NULL_HANDLE && ctx->vkDestroyAccelerationStructureKHR) {
        ctx->vkDestroyAccelerationStructureKHR(ctx->device, s.blas, nullptr);
        s.blas = VK_NULL_HANDLE;
    }
    destroy_buffer(s.blas_buffer);
    destroy_buffer(s.aabb_buffer);
    sectors.erase(it);

    UtilityFunctions::print("[VulkanASManager] Removed BLAS for sector (", p_pos.x, ",", p_pos.y, ",", p_pos.z, ")");
}

bool VulkanASManager::build_tlas() {
    if (sectors.empty()) {
        if (tlas != VK_NULL_HANDLE && ctx->vkDestroyAccelerationStructureKHR) {
            ctx->vkDestroyAccelerationStructureKHR(ctx->device, tlas, nullptr);
            tlas = VK_NULL_HANDLE;
        }
        destroy_buffer(tlas_buffer);
        destroy_buffer(tlas_instance_buffer);
        tlas_address = 0;
        return true;
    }

    // 1. Assemble TLAS instance records and calculate global brick offsets
    std::vector<VkAccelerationStructureInstanceKHR> instances;
    instances.reserve(sectors.size());

    uint32_t current_brick_offset = 0;
    size_t total_brick_bytes = 0;

    for (auto& pair : sectors) {
        SectorBLAS& s = pair.second;
        if (s.blas == VK_NULL_HANDLE || s.blas_address == 0) continue;

        s.global_brick_offset = current_brick_offset;
        current_brick_offset += s.brick_count;
        total_brick_bytes += s.brick_data.size();

        VkAccelerationStructureInstanceKHR inst;
        memset(&inst, 0, sizeof(inst));

        // Affine Transform: World position = SectorPos * 128 voxels
        inst.transform.matrix[0][0] = 1.0f;
        inst.transform.matrix[0][3] = static_cast<float>(s.sector_pos.x * 128);
        inst.transform.matrix[1][1] = 1.0f;
        inst.transform.matrix[1][3] = static_cast<float>(s.sector_pos.y * 128);
        inst.transform.matrix[2][2] = 1.0f;
        inst.transform.matrix[2][3] = static_cast<float>(s.sector_pos.z * 128);

        inst.instanceCustomIndex = s.global_brick_offset; // Custom index accessible via InstanceID() in shader
        inst.mask = 0xFF;
        inst.instanceShaderBindingTableRecordOffset = 0; // Hitgroup 0 (Caelix Micro-DDA)
        inst.flags = VK_GEOMETRY_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT_KHR;
        inst.accelerationStructureReference = s.blas_address;

        instances.push_back(inst);
    }

    total_active_bricks = current_brick_offset;

    if (instances.empty()) {
        return true;
    }

    // 2. Upload TLAS instance array
    VkDeviceSize instance_size = instances.size() * sizeof(VkAccelerationStructureInstanceKHR);
    if (!create_buffer(instance_size,
                       VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT_KHR | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                       tlas_instance_buffer)) {
        UtilityFunctions::printerr("[VulkanASManager] Failed to create TLAS instance buffer!");
        return false;
    }
    memcpy(tlas_instance_buffer.mapped_ptr, instances.data(), instance_size);

    // 3. Upload Consolidated Brick Buffer for all active sectors using persistent Sparse Pool
    VkDeviceSize required_size = (total_brick_bytes > 0) ? total_brick_bytes : 1096;
    if (global_brick_buffer.buffer == VK_NULL_HANDLE || global_brick_buffer.size < required_size) {
        VkDeviceSize pool_size = std::max<VkDeviceSize>(required_size, static_cast<VkDeviceSize>(128 * 1024 * 1024)); // 128 MB pool
        if (!create_buffer(pool_size,
                           VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
                           VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                           global_brick_buffer)) {
            UtilityFunctions::printerr("[VulkanASManager] Failed to allocate global brick pool buffer!");
            return false;
        }
    }

    if (total_brick_bytes > 0 && global_brick_buffer.mapped_ptr) {
        uint8_t* dst_ptr = static_cast<uint8_t*>(global_brick_buffer.mapped_ptr);
        for (const auto& pair : sectors) {
            const SectorBLAS& s = pair.second;
            if (!s.brick_data.empty()) {
                memcpy(dst_ptr + (s.global_brick_offset * 1096), s.brick_data.data(), s.brick_data.size());
            }
        }
    } else if (global_brick_buffer.mapped_ptr) {
        memset(global_brick_buffer.mapped_ptr, 0, 1096);
    }

    // 4. Setup TLAS Geometry
    VkAccelerationStructureGeometryKHR tlas_geom;
    memset(&tlas_geom, 0, sizeof(tlas_geom));
    tlas_geom.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR;
    tlas_geom.geometryType = VK_GEOMETRY_TYPE_INSTANCES_KHR;
    tlas_geom.flags = VK_GEOMETRY_OPAQUE_BIT_KHR;
    tlas_geom.geometry.instances.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_INSTANCES_DATA_KHR;
    tlas_geom.geometry.instances.arrayOfPointers = VK_FALSE;
    tlas_geom.geometry.instances.data.deviceAddress = tlas_instance_buffer.device_address;

    // 5. Query TLAS Build Sizes
    VkAccelerationStructureBuildGeometryInfoKHR tlas_build_info;
    memset(&tlas_build_info, 0, sizeof(tlas_build_info));
    tlas_build_info.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR;
    tlas_build_info.type = VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR;
    tlas_build_info.flags = VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT_KHR;
    tlas_build_info.mode = VK_BUILD_ACCELERATION_STRUCTURE_MODE_BUILD_KHR;
    tlas_build_info.geometryCount = 1;
    tlas_build_info.pGeometries = &tlas_geom;

    uint32_t inst_count = static_cast<uint32_t>(instances.size());
    VkAccelerationStructureBuildSizesInfoKHR tlas_size_info;
    memset(&tlas_size_info, 0, sizeof(tlas_size_info));
    tlas_size_info.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR;
    ctx->vkGetAccelerationStructureBuildSizesKHR(
        ctx->device,
        VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR,
        &tlas_build_info,
        &inst_count,
        &tlas_size_info
    );

    // 6. Ensure scratch buffer
    if (!ensure_scratch_buffer(tlas_size_info.buildScratchSize)) {
        return false;
    }

    // 7. Allocate TLAS Storage Buffer
    if (tlas != VK_NULL_HANDLE) {
        ctx->vkDestroyAccelerationStructureKHR(ctx->device, tlas, nullptr);
        tlas = VK_NULL_HANDLE;
    }
    destroy_buffer(tlas_buffer);

    if (!create_buffer(tlas_size_info.accelerationStructureSize,
                       VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_STORAGE_BIT_KHR | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
                       VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                       tlas_buffer)) {
        UtilityFunctions::printerr("[VulkanASManager] Failed to create TLAS storage buffer!");
        return false;
    }

    // 8. Create TLAS Handle
    VkAccelerationStructureCreateInfoKHR as_info;
    memset(&as_info, 0, sizeof(as_info));
    as_info.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_CREATE_INFO_KHR;
    as_info.buffer = tlas_buffer.buffer;
    as_info.offset = 0;
    as_info.size = tlas_size_info.accelerationStructureSize;
    as_info.type = VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR;

    if (ctx->vkCreateAccelerationStructureKHR(ctx->device, &as_info, nullptr, &tlas) != VK_SUCCESS) {
        UtilityFunctions::printerr("[VulkanASManager] Failed to create TLAS acceleration structure!");
        return false;
    }

    // 9. Query TLAS Device Address
    VkAccelerationStructureDeviceAddressInfoKHR addr_info;
    memset(&addr_info, 0, sizeof(addr_info));
    addr_info.sType = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_DEVICE_ADDRESS_INFO_KHR;
    addr_info.accelerationStructure = tlas;
    tlas_address = ctx->vkGetAccelerationStructureDeviceAddressKHR(ctx->device, &addr_info);

    // 10. Dispatch GPU Command to Build TLAS
    tlas_build_info.dstAccelerationStructure = tlas;
    tlas_build_info.scratchData.deviceAddress = scratch_buffer.device_address;

    VkAccelerationStructureBuildRangeInfoKHR range_info;
    memset(&range_info, 0, sizeof(range_info));
    range_info.primitiveCount = inst_count;
    range_info.primitiveOffset = 0;
    range_info.firstVertex = 0;
    range_info.transformOffset = 0;

    const VkAccelerationStructureBuildRangeInfoKHR* p_range_infos = &range_info;

    VkCommandBuffer cmd = begin_single_time_commands();
    ctx->vkCmdBuildAccelerationStructuresKHR(cmd, 1, &tlas_build_info, &p_range_infos);

    // Memory barrier: wait for TLAS build to complete before ray tracing execution
    VkMemoryBarrier barrier;
    memset(&barrier, 0, sizeof(barrier));
    barrier.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER;
    barrier.srcAccessMask = VK_ACCESS_ACCELERATION_STRUCTURE_WRITE_BIT_KHR;
    barrier.dstAccessMask = VK_ACCESS_ACCELERATION_STRUCTURE_READ_BIT_KHR;
    ctx->vkCmdPipelineBarrier(cmd,
                              VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,
                              VK_PIPELINE_STAGE_RAY_TRACING_SHADER_BIT_KHR,
                              0, 1, &barrier, 0, nullptr, 0, nullptr);

    end_single_time_commands(cmd);

    UtilityFunctions::print("[VulkanASManager] TLAS successfully built for ", inst_count,
                           " sector instances (Total active bricks: ", total_active_bricks,
                           ", TLAS Addr: 0x", String::num_uint64(tlas_address, 16), ")");
    return true;
}

} // namespace godot
