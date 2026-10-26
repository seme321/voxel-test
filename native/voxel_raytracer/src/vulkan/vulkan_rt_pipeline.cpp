#include "vulkan_rt_pipeline.h"
#include <godot_cpp/variant/utility_functions.hpp>
#include <cstring>
#include <algorithm>

namespace godot {

inline uint32_t align_up(uint32_t val, uint32_t alignment) {
    return (val + alignment - 1) & ~(alignment - 1);
}

VulkanRayTracingPipeline::VulkanRayTracingPipeline() {}

VulkanRayTracingPipeline::~VulkanRayTracingPipeline() {
    cleanup();
}

VkShaderModule VulkanRayTracingPipeline::create_shader_module(const uint32_t* code, size_t size_bytes) {
    if (!ctx || !ctx->device || !code || size_bytes == 0) return VK_NULL_HANDLE;

    VkShaderModuleCreateInfo create_info;
    memset(&create_info, 0, sizeof(create_info));
    create_info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    create_info.codeSize = size_bytes;
    create_info.pCode = code;

    VkShaderModule module = VK_NULL_HANDLE;
    // PFN_vkCreateShaderModule
    auto vkCreateShaderModule = (PFN_vkCreateShaderModule)ctx->vkGetDeviceProcAddr(ctx->device, "vkCreateShaderModule");
    if (!vkCreateShaderModule || vkCreateShaderModule(ctx->device, &create_info, nullptr, &module) != VK_SUCCESS) {
        UtilityFunctions::printerr("[VulkanRayTracingPipeline] Failed to create shader module!");
        return VK_NULL_HANDLE;
    }
    return module;
}

bool VulkanRayTracingPipeline::init(VulkanContext* p_ctx,
                                   const uint32_t* rgen_spv, size_t rgen_size,
                                   const uint32_t* rmiss_spv, size_t rmiss_size,
                                   const uint32_t* rint_spv, size_t rint_size,
                                   const uint32_t* rchit_spv, size_t rchit_size) {
    ctx = p_ctx;
    if (!ctx || !ctx->device) return false;

    UtilityFunctions::print("[VulkanRayTracingPipeline] Assembling Ray Tracing Pipeline & Descriptors...");

    // 1. Descriptor Set Layout Bindings
    std::vector<VkDescriptorSetLayoutBinding> bindings(4);
    memset(bindings.data(), 0, sizeof(VkDescriptorSetLayoutBinding) * bindings.size());

    // Binding 0: Top Level Acceleration Structure (TLAS)
    bindings[0].binding = 0;
    bindings[0].descriptorType = VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR;
    bindings[0].descriptorCount = 1;
    bindings[0].stageFlags = VK_SHADER_STAGE_RAYGEN_BIT_KHR | VK_SHADER_STAGE_CLOSEST_HIT_BIT_KHR;

    // Binding 1: Output Storage Image
    bindings[1].binding = 1;
    bindings[1].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
    bindings[1].descriptorCount = 1;
    bindings[1].stageFlags = VK_SHADER_STAGE_RAYGEN_BIT_KHR;

    // Binding 2: Brick Storage Buffer (g_Bricks)
    bindings[2].binding = 2;
    bindings[2].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    bindings[2].descriptorCount = 1;
    bindings[2].stageFlags = VK_SHADER_STAGE_INTERSECTION_BIT_KHR | VK_SHADER_STAGE_CLOSEST_HIT_BIT_KHR;

    // Binding 3: Camera Uniform Buffer
    bindings[3].binding = 3;
    bindings[3].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    bindings[3].descriptorCount = 1;
    bindings[3].stageFlags = VK_SHADER_STAGE_RAYGEN_BIT_KHR | VK_SHADER_STAGE_MISS_BIT_KHR | VK_SHADER_STAGE_CLOSEST_HIT_BIT_KHR;

    VkDescriptorSetLayoutCreateInfo layout_info;
    memset(&layout_info, 0, sizeof(layout_info));
    layout_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layout_info.bindingCount = static_cast<uint32_t>(bindings.size());
    layout_info.pBindings = bindings.data();

    if (ctx->vkCreateDescriptorSetLayout(ctx->device, &layout_info, nullptr, &descriptor_set_layout) != VK_SUCCESS) {
        UtilityFunctions::printerr("[VulkanRayTracingPipeline] Failed to create descriptor set layout!");
        return false;
    }

    // 2. Pipeline Layout
    VkPipelineLayoutCreateInfo pipeline_layout_info;
    memset(&pipeline_layout_info, 0, sizeof(pipeline_layout_info));
    pipeline_layout_info.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipeline_layout_info.setLayoutCount = 1;
    pipeline_layout_info.pSetLayouts = &descriptor_set_layout;

    if (ctx->vkCreatePipelineLayout(ctx->device, &pipeline_layout_info, nullptr, &pipeline_layout) != VK_SUCCESS) {
        UtilityFunctions::printerr("[VulkanRayTracingPipeline] Failed to create pipeline layout!");
        return false;
    }

    // 3. Compile Modules & Stages
    VkShaderModule rgen_module = create_shader_module(rgen_spv, rgen_size);
    VkShaderModule rmiss_module = create_shader_module(rmiss_spv, rmiss_size);
    VkShaderModule rint_module = create_shader_module(rint_spv, rint_size);
    VkShaderModule rchit_module = create_shader_module(rchit_spv, rchit_size);

    auto vkDestroyShaderModule = (PFN_vkDestroyShaderModule)ctx->vkGetDeviceProcAddr(ctx->device, "vkDestroyShaderModule");

    if (!rgen_module || !rmiss_module || !rint_module || !rchit_module) {
        UtilityFunctions::printerr("[VulkanRayTracingPipeline] Failed to compile one or more shader modules!");
        if (rgen_module && vkDestroyShaderModule) vkDestroyShaderModule(ctx->device, rgen_module, nullptr);
        if (rmiss_module && vkDestroyShaderModule) vkDestroyShaderModule(ctx->device, rmiss_module, nullptr);
        if (rint_module && vkDestroyShaderModule) vkDestroyShaderModule(ctx->device, rint_module, nullptr);
        if (rchit_module && vkDestroyShaderModule) vkDestroyShaderModule(ctx->device, rchit_module, nullptr);
        return false;
    }

    std::vector<VkPipelineShaderStageCreateInfo> stages(4);
    memset(stages.data(), 0, sizeof(VkPipelineShaderStageCreateInfo) * stages.size());

    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_RAYGEN_BIT_KHR;
    stages[0].module = rgen_module;
    stages[0].pName = "RayGenMain";

    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_MISS_BIT_KHR;
    stages[1].module = rmiss_module;
    stages[1].pName = "MissMain";

    stages[2].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[2].stage = VK_SHADER_STAGE_INTERSECTION_BIT_KHR;
    stages[2].module = rint_module;
    stages[2].pName = "IntersectionMain";

    stages[3].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[3].stage = VK_SHADER_STAGE_CLOSEST_HIT_BIT_KHR;
    stages[3].module = rchit_module;
    stages[3].pName = "ClosestHitMain";

    // 4. Shader Groups
    std::vector<VkRayTracingShaderGroupCreateInfoKHR> groups(3);
    memset(groups.data(), 0, sizeof(VkRayTracingShaderGroupCreateInfoKHR) * groups.size());

    // Group 0: Raygen
    groups[0].sType = VK_STRUCTURE_TYPE_RAY_TRACING_SHADER_GROUP_CREATE_INFO_KHR;
    groups[0].type = VK_RAY_TRACING_SHADER_GROUP_TYPE_GENERAL_KHR;
    groups[0].generalShader = 0;
    groups[0].closestHitShader = VK_SHADER_UNUSED_KHR;
    groups[0].anyHitShader = VK_SHADER_UNUSED_KHR;
    groups[0].intersectionShader = VK_SHADER_UNUSED_KHR;

    // Group 1: Miss
    groups[1].sType = VK_STRUCTURE_TYPE_RAY_TRACING_SHADER_GROUP_CREATE_INFO_KHR;
    groups[1].type = VK_RAY_TRACING_SHADER_GROUP_TYPE_GENERAL_KHR;
    groups[1].generalShader = 1;
    groups[1].closestHitShader = VK_SHADER_UNUSED_KHR;
    groups[1].anyHitShader = VK_SHADER_UNUSED_KHR;
    groups[1].intersectionShader = VK_SHADER_UNUSED_KHR;

    // Group 2: Procedural Hit Group (Intersection + ClosestHit)
    groups[2].sType = VK_STRUCTURE_TYPE_RAY_TRACING_SHADER_GROUP_CREATE_INFO_KHR;
    groups[2].type = VK_RAY_TRACING_SHADER_GROUP_TYPE_PROCEDURAL_HIT_GROUP_KHR;
    groups[2].generalShader = VK_SHADER_UNUSED_KHR;
    groups[2].closestHitShader = 3;
    groups[2].anyHitShader = VK_SHADER_UNUSED_KHR;
    groups[2].intersectionShader = 2;

    // 5. Create Ray Tracing Pipeline
    VkRayTracingPipelineCreateInfoKHR pipeline_info;
    memset(&pipeline_info, 0, sizeof(pipeline_info));
    pipeline_info.sType = VK_STRUCTURE_TYPE_RAY_TRACING_PIPELINE_CREATE_INFO_KHR;
    pipeline_info.stageCount = static_cast<uint32_t>(stages.size());
    pipeline_info.pStages = stages.data();
    pipeline_info.groupCount = static_cast<uint32_t>(groups.size());
    pipeline_info.pGroups = groups.data();
    pipeline_info.maxPipelineRayRecursionDepth = 1;
    pipeline_info.layout = pipeline_layout;

    VkResult res = ctx->vkCreateRayTracingPipelinesKHR(ctx->device, VK_NULL_HANDLE, VK_NULL_HANDLE, 1, &pipeline_info, nullptr, &pipeline);

    // Destroy temporary modules
    if (vkDestroyShaderModule) {
        vkDestroyShaderModule(ctx->device, rgen_module, nullptr);
        vkDestroyShaderModule(ctx->device, rmiss_module, nullptr);
        vkDestroyShaderModule(ctx->device, rint_module, nullptr);
        vkDestroyShaderModule(ctx->device, rchit_module, nullptr);
    }

    if (res != VK_SUCCESS || pipeline == VK_NULL_HANDLE) {
        UtilityFunctions::printerr("[VulkanRayTracingPipeline] vkCreateRayTracingPipelinesKHR failed with code: ", (int)res);
        return false;
    }

    UtilityFunctions::print("[VulkanRayTracingPipeline] Hardware Ray Tracing Pipeline successfully compiled!");

    // 6. Build Shader Binding Table (SBT)
    return create_sbt();
}

bool VulkanRayTracingPipeline::create_sbt() {
    uint32_t handle_size = ctx->sbt_handle_size;
    uint32_t handle_align = ctx->sbt_handle_alignment;
    uint32_t base_align = ctx->sbt_base_alignment;

    uint32_t handle_size_aligned = align_up(handle_size, handle_align);

    // Group 0: Raygen (1 record)
    raygen_region.stride = align_up(handle_size_aligned, base_align);
    raygen_region.size = raygen_region.stride;

    // Group 1: Miss (1 record)
    miss_region.stride = handle_size_aligned;
    miss_region.size = align_up(handle_size_aligned, base_align);

    // Group 2: Hit Group (1 record)
    hit_region.stride = handle_size_aligned;
    hit_region.size = align_up(handle_size_aligned, base_align);

    uint32_t sbt_size = raygen_region.size + miss_region.size + hit_region.size;

    // Allocate SBT Buffer
    VkBufferCreateInfo buffer_info;
    memset(&buffer_info, 0, sizeof(buffer_info));
    buffer_info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    buffer_info.size = sbt_size;
    buffer_info.usage = VK_BUFFER_USAGE_SHADER_BINDING_TABLE_BIT_KHR | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
    buffer_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

    if (ctx->vkCreateBuffer(ctx->device, &buffer_info, nullptr, &sbt_buffer) != VK_SUCCESS) {
        UtilityFunctions::printerr("[VulkanRayTracingPipeline] Failed to create SBT buffer!");
        return false;
    }

    VkMemoryRequirements mem_reqs;
    ctx->vkGetBufferMemoryRequirements(ctx->device, sbt_buffer, &mem_reqs);

    VkMemoryAllocateFlagsInfo flags_info;
    memset(&flags_info, 0, sizeof(flags_info));
    flags_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO;
    flags_info.flags = VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT;

    VkMemoryAllocateInfo alloc_info;
    memset(&alloc_info, 0, sizeof(alloc_info));
    alloc_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.pNext = &flags_info;
    alloc_info.allocationSize = mem_reqs.size;
    alloc_info.memoryTypeIndex = ctx->find_memory_type(mem_reqs.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);

    if (ctx->vkAllocateMemory(ctx->device, &alloc_info, nullptr, &sbt_memory) != VK_SUCCESS) {
        UtilityFunctions::printerr("[VulkanRayTracingPipeline] Failed to allocate SBT memory!");
        return false;
    }

    ctx->vkBindBufferMemory(ctx->device, sbt_buffer, sbt_memory, 0);
    sbt_address = ctx->get_buffer_address(sbt_buffer);

    // Set regions device addresses
    raygen_region.deviceAddress = sbt_address;
    miss_region.deviceAddress = sbt_address + raygen_region.size;
    hit_region.deviceAddress = sbt_address + raygen_region.size + miss_region.size;

    // Fetch Shader Group Handles from Pipeline
    uint32_t group_count = 3;
    uint32_t data_size = group_count * handle_size;
    std::vector<uint8_t> handles(data_size);

    if (ctx->vkGetRayTracingShaderGroupHandlesKHR(ctx->device, pipeline, 0, group_count, data_size, handles.data()) != VK_SUCCESS) {
        UtilityFunctions::printerr("[VulkanRayTracingPipeline] Failed to get shader group handles!");
        return false;
    }

    // Map and Copy Handles into Strided Layout
    void* mapped_ptr = nullptr;
    ctx->vkMapMemory(ctx->device, sbt_memory, 0, sbt_size, 0, &mapped_ptr);
    uint8_t* p_sbt = reinterpret_cast<uint8_t*>(mapped_ptr);

    // Copy Raygen
    memcpy(p_sbt, handles.data(), handle_size);

    // Copy Miss
    p_sbt += raygen_region.size;
    memcpy(p_sbt, handles.data() + handle_size, handle_size);

    // Copy Hit Group
    p_sbt += miss_region.size;
    memcpy(p_sbt, handles.data() + handle_size * 2, handle_size);

    ctx->vkUnmapMemory(ctx->device, sbt_memory);

    UtilityFunctions::print("[VulkanRayTracingPipeline] Shader Binding Table (SBT) initialized (Total size: ", sbt_size, "B, Addr: 0x", String::num_uint64(sbt_address, 16), ")");
    return true;
}

void VulkanRayTracingPipeline::cleanup() {
    if (!ctx || !ctx->device) return;

    if (pipeline != VK_NULL_HANDLE) {
        auto vkDestroyPipeline = (PFN_vkDestroyPipeline)ctx->vkGetDeviceProcAddr(ctx->device, "vkDestroyPipeline");
        if (vkDestroyPipeline) vkDestroyPipeline(ctx->device, pipeline, nullptr);
        pipeline = VK_NULL_HANDLE;
    }

    if (pipeline_layout != VK_NULL_HANDLE && ctx->vkDestroyPipelineLayout) {
        ctx->vkDestroyPipelineLayout(ctx->device, pipeline_layout, nullptr);
        pipeline_layout = VK_NULL_HANDLE;
    }

    if (descriptor_set_layout != VK_NULL_HANDLE && ctx->vkDestroyDescriptorSetLayout) {
        ctx->vkDestroyDescriptorSetLayout(ctx->device, descriptor_set_layout, nullptr);
        descriptor_set_layout = VK_NULL_HANDLE;
    }

    if (sbt_buffer != VK_NULL_HANDLE && ctx->vkDestroyBuffer) {
        ctx->vkDestroyBuffer(ctx->device, sbt_buffer, nullptr);
        sbt_buffer = VK_NULL_HANDLE;
    }

    if (sbt_memory != VK_NULL_HANDLE && ctx->vkFreeMemory) {
        ctx->vkFreeMemory(ctx->device, sbt_memory, nullptr);
        sbt_memory = VK_NULL_HANDLE;
    }
}

} // namespace godot
