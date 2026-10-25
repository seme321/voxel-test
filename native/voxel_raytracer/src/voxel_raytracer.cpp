#include "voxel_raytracer.h"
#include "vulkan/embedded_shaders.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <cmath>
#include <cstring>

namespace godot {

void VoxelRayTracer::_bind_methods() {
    // Diagnostics
    ClassDB::bind_method(D_METHOD("is_rtx_supported"), &VoxelRayTracer::is_rtx_supported);
    ClassDB::bind_method(D_METHOD("get_gpu_name"), &VoxelRayTracer::get_gpu_name);
    ClassDB::bind_method(D_METHOD("get_raytracer_status"), &VoxelRayTracer::get_raytracer_status);

    // Config
    ClassDB::bind_method(D_METHOD("init_raytracer", "width", "height"), &VoxelRayTracer::init_raytracer);
    ClassDB::bind_method(D_METHOD("set_render_width", "width"), &VoxelRayTracer::set_render_width);
    ClassDB::bind_method(D_METHOD("get_render_width"), &VoxelRayTracer::get_render_width);
    ClassDB::bind_method(D_METHOD("set_render_height", "height"), &VoxelRayTracer::set_render_height);
    ClassDB::bind_method(D_METHOD("get_render_height"), &VoxelRayTracer::get_render_height);
    ClassDB::bind_method(D_METHOD("set_ray_bounces", "bounces"), &VoxelRayTracer::set_ray_bounces);
    ClassDB::bind_method(D_METHOD("get_ray_bounces"), &VoxelRayTracer::get_ray_bounces);

    ADD_PROPERTY(PropertyInfo(Variant::INT, "render_width"), "set_render_width", "get_render_width");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "render_height"), "set_render_height", "get_render_height");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "ray_bounces"), "set_ray_bounces", "get_ray_bounces");

    // Sector Upload
    ClassDB::bind_method(D_METHOD("upload_sector_aabbs", "sector_pos", "aabb_bytes"), &VoxelRayTracer::upload_sector_aabbs);
    ClassDB::bind_method(D_METHOD("upload_sector_bricks", "sector_pos", "brick_bytes"), &VoxelRayTracer::upload_sector_bricks);
    ClassDB::bind_method(D_METHOD("patch_sector_brick", "sector_pos", "brick_index", "brick_bytes"), &VoxelRayTracer::patch_sector_brick);
    ClassDB::bind_method(D_METHOD("remove_sector", "sector_pos"), &VoxelRayTracer::remove_sector);
    ClassDB::bind_method(D_METHOD("get_active_sector_count"), &VoxelRayTracer::get_active_sector_count);

    // Execution & Presentation
    ClassDB::bind_method(D_METHOD("render_frame", "camera_transform", "fov"), &VoxelRayTracer::render_frame);
    ClassDB::bind_method(D_METHOD("get_output_texture"), &VoxelRayTracer::get_output_texture);
    ClassDB::bind_method(D_METHOD("get_output_image"), &VoxelRayTracer::get_output_image);
}

VoxelRayTracer::VoxelRayTracer() {
    UtilityFunctions::print("[VoxelRayTracer] Instantiating Native C++ GDExtension Ray Tracer...");
}

VoxelRayTracer::~VoxelRayTracer() {
    active_sectors.clear();
    cleanup_render_targets();

    if (as_manager) {
        as_manager->cleanup();
        as_manager.reset();
    }
    if (rt_pipeline) {
        rt_pipeline->cleanup();
        rt_pipeline.reset();
    }
    if (vk_context) {
        vk_context->cleanup();
        vk_context.reset();
    }
    output_image.unref();
    output_texture.unref();
}

bool VoxelRayTracer::is_rtx_supported() const {
    return vk_context ? vk_context->rtx_supported : false;
}

String VoxelRayTracer::get_gpu_name() const {
    return vk_context ? vk_context->device_name.c_str() : gpu_device_name;
}

String VoxelRayTracer::get_raytracer_status() const {
    if (!is_initialized || !vk_context || !vk_context->rtx_supported) {
        return "Uninitialized / Hardware RT Unavailable";
    }
    String status = String("Ready (Hardware RT Active) | GPU: ") + vk_context->device_name.c_str() +
                    " | SBT Handle: " + String::num_int64(vk_context->sbt_handle_size) + "B" +
                    " | Sectors: " + String::num_int64(as_manager ? as_manager->get_sector_count() : 0) +
                    " | Resolution: " + String::num_int64(render_width) + "x" + String::num_int64(render_height);
    if (as_manager && as_manager->get_tlas() != VK_NULL_HANDLE) {
        status += " | TLAS Addr: 0x" + String::num_uint64(as_manager->tlas_address, 16);
    }
    return status;
}

bool VoxelRayTracer::init_render_targets() {
    if (!vk_context || !vk_context->device || !as_manager) return false;

    cleanup_render_targets();

    // 1. Create Output Storage Image (VK_FORMAT_R8G8B8A8_UNORM)
    VkImageCreateInfo img_info;
    memset(&img_info, 0, sizeof(img_info));
    img_info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    img_info.imageType = VK_IMAGE_TYPE_2D;
    img_info.format = VK_FORMAT_R8G8B8A8_UNORM;
    img_info.extent.width = static_cast<uint32_t>(render_width);
    img_info.extent.height = static_cast<uint32_t>(render_height);
    img_info.extent.depth = 1;
    img_info.mipLevels = 1;
    img_info.arrayLayers = 1;
    img_info.samples = VK_SAMPLE_COUNT_1_BIT;
    img_info.tiling = VK_IMAGE_TILING_OPTIMAL;
    img_info.usage = VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    img_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    img_info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;

    if (vk_context->vkCreateImage(vk_context->device, &img_info, nullptr, &vk_render_target) != VK_SUCCESS) {
        UtilityFunctions::printerr("[VoxelRayTracer] Failed to create output VkImage!");
        return false;
    }

    VkMemoryRequirements mem_reqs;
    vk_context->vkGetImageMemoryRequirements(vk_context->device, vk_render_target, &mem_reqs);

    VkMemoryAllocateInfo alloc_info;
    memset(&alloc_info, 0, sizeof(alloc_info));
    alloc_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_reqs.size;
    alloc_info.memoryTypeIndex = vk_context->find_memory_type(mem_reqs.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

    if (vk_context->vkAllocateMemory(vk_context->device, &alloc_info, nullptr, &vk_render_target_memory) != VK_SUCCESS) {
        UtilityFunctions::printerr("[VoxelRayTracer] Failed to allocate memory for output image!");
        return false;
    }

    vk_context->vkBindImageMemory(vk_context->device, vk_render_target, vk_render_target_memory, 0);

    // 2. Create Image View
    VkImageViewCreateInfo view_info;
    memset(&view_info, 0, sizeof(view_info));
    view_info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view_info.image = vk_render_target;
    view_info.viewType = VK_IMAGE_VIEW_TYPE_2D;
    view_info.format = VK_FORMAT_R8G8B8A8_UNORM;
    view_info.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    view_info.subresourceRange.baseMipLevel = 0;
    view_info.subresourceRange.levelCount = 1;
    view_info.subresourceRange.baseArrayLayer = 0;
    view_info.subresourceRange.layerCount = 1;

    if (vk_context->vkCreateImageView(vk_context->device, &view_info, nullptr, &vk_render_target_view) != VK_SUCCESS) {
        UtilityFunctions::printerr("[VoxelRayTracer] Failed to create output VkImageView!");
        return false;
    }

    // 3. Create Double Buffering Staging Buffers & Command Buffers & Fences
    VkDeviceSize pixel_data_size = static_cast<VkDeviceSize>(render_width * render_height * 4);
    for (uint32_t i = 0; i < MAX_FRAMES_IN_FLIGHT; ++i) {
        if (!as_manager->create_buffer(pixel_data_size,
                                       VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                       frames[i].staging_output_buffer)) {
            UtilityFunctions::printerr("[VoxelRayTracer] Failed to create staging output buffer for frame ", (int)i);
            return false;
        }

        VkCommandBufferAllocateInfo alloc_info;
        memset(&alloc_info, 0, sizeof(alloc_info));
        alloc_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc_info.commandPool = vk_context->command_pool;
        alloc_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc_info.commandBufferCount = 1;

        if (vk_context->vkAllocateCommandBuffers(vk_context->device, &alloc_info, &frames[i].command_buffer) != VK_SUCCESS) {
            UtilityFunctions::printerr("[VoxelRayTracer] Failed to allocate command buffer for frame ", (int)i);
            return false;
        }

        VkFenceCreateInfo fence_info;
        memset(&fence_info, 0, sizeof(fence_info));
        fence_info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fence_info.flags = VK_FENCE_CREATE_SIGNALED_BIT;

        if (vk_context->vkCreateFence(vk_context->device, &fence_info, nullptr, &frames[i].fence) != VK_SUCCESS) {
            UtilityFunctions::printerr("[VoxelRayTracer] Failed to create fence for frame ", (int)i);
            return false;
        }
        frames[i].has_rendered = false;
    }
    current_frame = 0;

    // 4. Create Camera Uniform Buffer
    if (!as_manager->create_buffer(256,
                                   VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                                   VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                   camera_uniform_buffer)) {
        UtilityFunctions::printerr("[VoxelRayTracer] Failed to create camera uniform buffer!");
        return false;
    }

    // 5. Transition VkImage to VK_IMAGE_LAYOUT_GENERAL
    VkCommandBuffer cmd = as_manager->begin_single_time_commands();
    VkImageMemoryBarrier barrier;
    memset(&barrier, 0, sizeof(barrier));
    barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    barrier.newLayout = VK_IMAGE_LAYOUT_GENERAL;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = vk_render_target;
    barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;
    barrier.srcAccessMask = 0;
    barrier.dstAccessMask = VK_ACCESS_SHADER_WRITE_BIT;

    vk_context->vkCmdPipelineBarrier(cmd,
                                     VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                                     VK_PIPELINE_STAGE_RAY_TRACING_SHADER_BIT_KHR,
                                     0, 0, nullptr, 0, nullptr, 1, &barrier);
    as_manager->end_single_time_commands(cmd);

    // 6. Create Descriptor Pool
    VkDescriptorPoolSize pool_sizes[4];
    memset(pool_sizes, 0, sizeof(pool_sizes));
    pool_sizes[0].type = VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR;
    pool_sizes[0].descriptorCount = 1;
    pool_sizes[1].type = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
    pool_sizes[1].descriptorCount = 1;
    pool_sizes[2].type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    pool_sizes[2].descriptorCount = 1;
    pool_sizes[3].type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    pool_sizes[3].descriptorCount = 1;

    VkDescriptorPoolCreateInfo pool_create_info;
    memset(&pool_create_info, 0, sizeof(pool_create_info));
    pool_create_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    pool_create_info.maxSets = 1;
    pool_create_info.poolSizeCount = 4;
    pool_create_info.pPoolSizes = pool_sizes;

    if (vk_context->vkCreateDescriptorPool(vk_context->device, &pool_create_info, nullptr, &descriptor_pool) != VK_SUCCESS) {
        UtilityFunctions::printerr("[VoxelRayTracer] Failed to create descriptor pool!");
        return false;
    }

    // Allocate Descriptor Set
    VkDescriptorSetAllocateInfo ds_alloc_info;
    memset(&ds_alloc_info, 0, sizeof(ds_alloc_info));
    ds_alloc_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    ds_alloc_info.descriptorPool = descriptor_pool;
    ds_alloc_info.descriptorSetCount = 1;
    ds_alloc_info.pSetLayouts = &rt_pipeline->descriptor_set_layout;

    if (vk_context->vkAllocateDescriptorSets(vk_context->device, &ds_alloc_info, &descriptor_set) != VK_SUCCESS) {
        UtilityFunctions::printerr("[VoxelRayTracer] Failed to allocate ray tracing descriptor set!");
        return false;
    }

    // 7. Godot Presentation Image & Texture Buffers
    output_image = Image::create_empty(render_width, render_height, false, Image::FORMAT_RGBA8);
    output_pixel_buffer.resize(render_width * render_height * 4);
    output_texture = ImageTexture::create_from_image(output_image);

    tlas_dirty = true;
    return true;
}

void VoxelRayTracer::cleanup_render_targets() {
    if (!vk_context || !vk_context->device) return;

    if (vk_context->vkDeviceWaitIdle) {
        vk_context->vkDeviceWaitIdle(vk_context->device);
    }

    if (descriptor_pool != VK_NULL_HANDLE) {
        vk_context->vkDestroyDescriptorPool(vk_context->device, descriptor_pool, nullptr);
        descriptor_pool = VK_NULL_HANDLE;
        descriptor_set = VK_NULL_HANDLE;
    }

    for (uint32_t i = 0; i < MAX_FRAMES_IN_FLIGHT; ++i) {
        if (frames[i].fence != VK_NULL_HANDLE && vk_context->vkDestroyFence) {
            vk_context->vkDestroyFence(vk_context->device, frames[i].fence, nullptr);
            frames[i].fence = VK_NULL_HANDLE;
        }
        if (frames[i].command_buffer != VK_NULL_HANDLE && vk_context->vkFreeCommandBuffers) {
            vk_context->vkFreeCommandBuffers(vk_context->device, vk_context->command_pool, 1, &frames[i].command_buffer);
            frames[i].command_buffer = VK_NULL_HANDLE;
        }
        if (as_manager) {
            as_manager->destroy_buffer(frames[i].staging_output_buffer);
        }
        frames[i].has_rendered = false;
    }

    if (as_manager) {
        as_manager->destroy_buffer(camera_uniform_buffer);
    }

    if (vk_render_target_view != VK_NULL_HANDLE) {
        vk_context->vkDestroyImageView(vk_context->device, vk_render_target_view, nullptr);
        vk_render_target_view = VK_NULL_HANDLE;
    }

    if (vk_render_target != VK_NULL_HANDLE) {
        vk_context->vkDestroyImage(vk_context->device, vk_render_target, nullptr);
        vk_render_target = VK_NULL_HANDLE;
    }

    if (vk_render_target_memory != VK_NULL_HANDLE) {
        vk_context->vkFreeMemory(vk_context->device, vk_render_target_memory, nullptr);
        vk_render_target_memory = VK_NULL_HANDLE;
    }
}

bool VoxelRayTracer::update_descriptor_set() {
    if (!vk_context || !vk_context->device || descriptor_set == VK_NULL_HANDLE) return false;
    if (!as_manager || as_manager->get_tlas() == VK_NULL_HANDLE) return false;

    // Binding 0: Top Level Acceleration Structure
    VkWriteDescriptorSetAccelerationStructureKHR as_desc;
    memset(&as_desc, 0, sizeof(as_desc));
    as_desc.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET_ACCELERATION_STRUCTURE_KHR;
    as_desc.accelerationStructureCount = 1;
    VkAccelerationStructureKHR tlas_h = as_manager->get_tlas();
    as_desc.pAccelerationStructures = &tlas_h;

    VkWriteDescriptorSet writes[4];
    memset(writes, 0, sizeof(writes));

    writes[0].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writes[0].pNext = &as_desc;
    writes[0].dstSet = descriptor_set;
    writes[0].dstBinding = 0;
    writes[0].descriptorCount = 1;
    writes[0].descriptorType = VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR;

    // Binding 1: Output Storage Image
    VkDescriptorImageInfo img_desc;
    memset(&img_desc, 0, sizeof(img_desc));
    img_desc.imageView = vk_render_target_view;
    img_desc.imageLayout = VK_IMAGE_LAYOUT_GENERAL;

    writes[1].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writes[1].dstSet = descriptor_set;
    writes[1].dstBinding = 1;
    writes[1].descriptorCount = 1;
    writes[1].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
    writes[1].pImageInfo = &img_desc;

    // Binding 2: Unified Bricks SSBO
    VkDescriptorBufferInfo brick_desc;
    memset(&brick_desc, 0, sizeof(brick_desc));
    brick_desc.buffer = as_manager->get_global_brick_buffer();
    brick_desc.offset = 0;
    brick_desc.range = as_manager->get_global_brick_buffer_size();

    writes[2].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writes[2].dstSet = descriptor_set;
    writes[2].dstBinding = 2;
    writes[2].descriptorCount = 1;
    writes[2].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    writes[2].pBufferInfo = &brick_desc;

    // Binding 3: Camera Uniform Buffer
    VkDescriptorBufferInfo cam_desc;
    memset(&cam_desc, 0, sizeof(cam_desc));
    cam_desc.buffer = camera_uniform_buffer.buffer;
    cam_desc.offset = 0;
    cam_desc.range = sizeof(CameraParams);

    writes[3].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writes[3].dstSet = descriptor_set;
    writes[3].dstBinding = 3;
    writes[3].descriptorCount = 1;
    writes[3].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    writes[3].pBufferInfo = &cam_desc;

    vk_context->vkUpdateDescriptorSets(vk_context->device, 4, writes, 0, nullptr);
    return true;
}

bool VoxelRayTracer::init_raytracer(int p_width, int p_height) {
    if (p_width <= 0 || p_height <= 0) {
        UtilityFunctions::printerr("[VoxelRayTracer] Invalid dimensions: ", p_width, "x", p_height);
        return false;
    }

    render_width = p_width;
    render_height = p_height;

    // 1. Initialize Vulkan Ray Tracing Context
    if (!vk_context) {
        vk_context = std::make_unique<VulkanContext>();
        if (!vk_context->init()) {
            UtilityFunctions::printerr("[VoxelRayTracer] Failed to initialize Vulkan Ray Tracing Context!");
            rtx_available = false;
            return false;
        }
        rtx_available = vk_context->rtx_supported;
        gpu_device_name = vk_context->device_name.c_str();
    }

    // 2. Initialize Vulkan Hardware Ray Tracing Pipeline & SBT
    if (!rt_pipeline) {
        rt_pipeline = std::make_unique<VulkanRayTracingPipeline>();
        if (!rt_pipeline->init(vk_context.get(),
                               Shaders::kRayGenSpv, Shaders::kRayGenSpv_size,
                               Shaders::kMissSpv, Shaders::kMissSpv_size,
                               Shaders::kIntersectionSpv, Shaders::kIntersectionSpv_size,
                               Shaders::kClosestHitSpv, Shaders::kClosestHitSpv_size)) {
            UtilityFunctions::printerr("[VoxelRayTracer] Failed to compile Ray Tracing Pipeline & SBT!");
            return false;
        }
    }

    // 3. Initialize Vulkan Acceleration Structure Manager
    if (!as_manager) {
        as_manager = std::make_unique<VulkanASManager>();
        if (!as_manager->init(vk_context.get())) {
            UtilityFunctions::printerr("[VoxelRayTracer] Failed to initialize Vulkan AS Manager!");
            return false;
        }
    }

    // 4. Initialize Offscreen Render Targets & Presentation Buffers
    if (!init_render_targets()) {
        UtilityFunctions::printerr("[VoxelRayTracer] Failed to initialize Render Targets!");
        return false;
    }

    is_initialized = true;
    UtilityFunctions::print("[VoxelRayTracer] Hardware Ray Tracer initialized successfully on: ",
                           gpu_device_name, " at ", render_width, "x", render_height);
    return true;
}

void VoxelRayTracer::set_render_width(int p_width) {
    if (p_width > 0 && p_width != render_width) {
        render_width = p_width;
        if (is_initialized) {
            init_raytracer(render_width, render_height);
        }
    }
}

int VoxelRayTracer::get_render_width() const {
    return render_width;
}

void VoxelRayTracer::set_render_height(int p_height) {
    if (p_height > 0 && p_height != render_height) {
        render_height = p_height;
        if (is_initialized) {
            init_raytracer(render_width, render_height);
        }
    }
}

int VoxelRayTracer::get_render_height() const {
    return render_height;
}

void VoxelRayTracer::set_ray_bounces(int p_bounces) {
    ray_bounces = p_bounces;
}

int VoxelRayTracer::get_ray_bounces() const {
    return ray_bounces;
}

void VoxelRayTracer::upload_sector_aabbs(const Vector3i &p_pos, const PackedByteArray &p_aabbs) {
    int64_t key = get_sector_key(p_pos);
    SectorData& data = active_sectors[key];
    data.pos = p_pos;
    data.aabbs = p_aabbs;

    if (as_manager && data.aabbs.size() > 0 && data.bricks.size() > 0) {
        uint32_t aabb_count = static_cast<uint32_t>(data.aabbs.size() / 24);
        uint32_t brick_count = static_cast<uint32_t>(data.bricks.size() / 1096);
        as_manager->build_sector_blas(p_pos, aabb_count, data.aabbs.ptr(), brick_count, data.bricks.ptr());
        tlas_dirty = true;
    }
}

void VoxelRayTracer::upload_sector_bricks(const Vector3i &p_pos, const PackedByteArray &p_bricks) {
    int64_t key = get_sector_key(p_pos);
    SectorData& data = active_sectors[key];
    data.pos = p_pos;
    data.bricks = p_bricks;

    if (as_manager && data.aabbs.size() > 0 && data.bricks.size() > 0) {
        uint32_t aabb_count = static_cast<uint32_t>(data.aabbs.size() / 24);
        uint32_t brick_count = static_cast<uint32_t>(data.bricks.size() / 1096);
        as_manager->build_sector_blas(p_pos, aabb_count, data.aabbs.ptr(), brick_count, data.bricks.ptr());
        tlas_dirty = true;
    }
}

bool VoxelRayTracer::patch_sector_brick(const Vector3i &p_pos, int p_bindex, const PackedByteArray &p_brick_bytes) {
    if (!as_manager || p_brick_bytes.size() < 1096 || p_bindex < 0) {
        return false;
    }

    bool ok = as_manager->patch_sector_brick(p_pos, static_cast<uint32_t>(p_bindex), p_brick_bytes.ptr());
    if (ok) {
        int64_t key = get_sector_key(p_pos);
        auto it = active_sectors.find(key);
        if (it != active_sectors.end()) {
            const uint8_t* raw = it->second.bricks.ptr();
            uint32_t count = static_cast<uint32_t>(it->second.bricks.size() / 1096);
            for (uint32_t i = 0; i < count; ++i) {
                uint32_t w0 = *reinterpret_cast<const uint32_t*>(raw + i * 1096);
                if ((w0 & 0xFFFu) == static_cast<uint32_t>(p_bindex)) {
                    memcpy(it->second.bricks.ptrw() + i * 1096, p_brick_bytes.ptr(), 1096);
                    break;
                }
            }
        }
    }
    return ok;
}

void VoxelRayTracer::remove_sector(const Vector3i &p_pos) {
    int64_t key = get_sector_key(p_pos);
    active_sectors.erase(key);
    if (as_manager) {
        as_manager->remove_sector_blas(p_pos);
        tlas_dirty = true;
    }
}

int VoxelRayTracer::get_active_sector_count() const {
    return as_manager ? static_cast<int>(as_manager->get_sector_count()) : static_cast<int>(active_sectors.size());
}

void VoxelRayTracer::render_frame(const Transform3D &p_cam_transform, float p_fov) {
    if (!is_initialized || !vk_context || !vk_context->rtx_supported || !as_manager || !rt_pipeline) {
        return;
    }

    FrameSync& frame = frames[current_frame];

    // 1. Wait for this frame slot's previous GPU execution to complete
    if (frame.fence != VK_NULL_HANDLE && vk_context->vkWaitForFences) {
        vk_context->vkWaitForFences(vk_context->device, 1, &frame.fence, VK_TRUE, UINT64_MAX);
    }

    // 2. Transfer completed pixels from previous frame into Godot Image & Texture
    if (frame.has_rendered && frame.staging_output_buffer.mapped_ptr && output_pixel_buffer.size() >= render_width * render_height * 4) {
        memcpy(output_pixel_buffer.ptrw(), frame.staging_output_buffer.mapped_ptr, render_width * render_height * 4);
        output_image->set_data(render_width, render_height, false, Image::FORMAT_RGBA8, output_pixel_buffer);
        output_texture->update(output_image);
    }

    if (frame.fence != VK_NULL_HANDLE && vk_context->vkResetFences) {
        vk_context->vkResetFences(vk_context->device, 1, &frame.fence);
    }

    // 3. Rebuild TLAS and update descriptors if geometry changed
    if (tlas_dirty) {
        as_manager->build_tlas();
        tlas_dirty = false;
        update_descriptor_set();
    }

    if (as_manager->get_tlas() == VK_NULL_HANDLE) {
        return;
    }

    // 4. Compute Camera Matrices (Column-major format for HLSL)
    CameraParams cam;
    memset(&cam, 0, sizeof(cam));

    Vector3 right = p_cam_transform.basis.get_column(0);
    Vector3 up = p_cam_transform.basis.get_column(1);
    Vector3 back = p_cam_transform.basis.get_column(2);
    Vector3 origin = p_cam_transform.origin;

    cam.viewInverse[0]  = right.x;
    cam.viewInverse[1]  = right.y;
    cam.viewInverse[2]  = right.z;
    cam.viewInverse[3]  = 0.0f;
    cam.viewInverse[4]  = up.x;
    cam.viewInverse[5]  = up.y;
    cam.viewInverse[6]  = up.z;
    cam.viewInverse[7]  = 0.0f;
    cam.viewInverse[8]  = back.x;
    cam.viewInverse[9]  = back.y;
    cam.viewInverse[10] = back.z;
    cam.viewInverse[11] = 0.0f;
    cam.viewInverse[12] = origin.x;
    cam.viewInverse[13] = origin.y;
    cam.viewInverse[14] = origin.z;
    cam.viewInverse[15] = 1.0f;

    float aspect = static_cast<float>(render_width) / static_cast<float>(render_height);
    float fov_rad = p_fov * 3.14159265358979323846f / 180.0f;
    float tan_half_fov = std::tan(fov_rad * 0.5f);

    cam.projInverse[0]  = aspect * tan_half_fov;
    cam.projInverse[5]  = tan_half_fov;
    cam.projInverse[14] = -1.0f;
    cam.projInverse[15] = 1.0f;

    cam.camPos[0] = origin.x;
    cam.camPos[1] = origin.y;
    cam.camPos[2] = origin.z;
    cam.camPos[3] = 1.0f;

    cam.fov = p_fov;
    cam.width = static_cast<uint32_t>(render_width);
    cam.height = static_cast<uint32_t>(render_height);
    cam.frameIndex = frame_index++;

    if (camera_uniform_buffer.mapped_ptr) {
        memcpy(camera_uniform_buffer.mapped_ptr, &cam, sizeof(CameraParams));
    }

    // 5. Record Ray Tracing commands into frame.command_buffer
    VkCommandBuffer cmd = frame.command_buffer;
    VkCommandBufferBeginInfo begin_info;
    memset(&begin_info, 0, sizeof(begin_info));
    begin_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vk_context->vkBeginCommandBuffer(cmd, &begin_info);

    // Bind RT Pipeline
    vk_context->vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_RAY_TRACING_KHR, rt_pipeline->pipeline);

    // Bind Descriptor Set
    vk_context->vkCmdBindDescriptorSets(cmd,
                                       VK_PIPELINE_BIND_POINT_RAY_TRACING_KHR,
                                       rt_pipeline->pipeline_layout,
                                       0, 1, &descriptor_set, 0, nullptr);

    // Trace Rays
    vk_context->vkCmdTraceRaysKHR(cmd,
                                 &rt_pipeline->raygen_region,
                                 &rt_pipeline->miss_region,
                                 &rt_pipeline->hit_region,
                                 &rt_pipeline->callable_region,
                                 static_cast<uint32_t>(render_width),
                                 static_cast<uint32_t>(render_height),
                                 1);

    // 6. Memory Barrier & Copy Image -> Current Staging Buffer
    VkImageMemoryBarrier barrier_to_copy;
    memset(&barrier_to_copy, 0, sizeof(barrier_to_copy));
    barrier_to_copy.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier_to_copy.oldLayout = VK_IMAGE_LAYOUT_GENERAL;
    barrier_to_copy.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    barrier_to_copy.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier_to_copy.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier_to_copy.image = vk_render_target;
    barrier_to_copy.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier_to_copy.subresourceRange.baseMipLevel = 0;
    barrier_to_copy.subresourceRange.levelCount = 1;
    barrier_to_copy.subresourceRange.baseArrayLayer = 0;
    barrier_to_copy.subresourceRange.layerCount = 1;
    barrier_to_copy.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
    barrier_to_copy.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;

    vk_context->vkCmdPipelineBarrier(cmd,
                                     VK_PIPELINE_STAGE_RAY_TRACING_SHADER_BIT_KHR,
                                     VK_PIPELINE_STAGE_TRANSFER_BIT,
                                     0, 0, nullptr, 0, nullptr, 1, &barrier_to_copy);

    VkBufferImageCopy copy_region;
    memset(&copy_region, 0, sizeof(copy_region));
    copy_region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    copy_region.imageSubresource.layerCount = 1;
    copy_region.imageExtent.width = static_cast<uint32_t>(render_width);
    copy_region.imageExtent.height = static_cast<uint32_t>(render_height);
    copy_region.imageExtent.depth = 1;

    vk_context->vkCmdCopyImageToBuffer(cmd,
                                       vk_render_target,
                                       VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                                       frame.staging_output_buffer.buffer,
                                       1, &copy_region);

    // Transition back to GENERAL layout
    VkImageMemoryBarrier barrier_to_general = barrier_to_copy;
    barrier_to_general.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    barrier_to_general.newLayout = VK_IMAGE_LAYOUT_GENERAL;
    barrier_to_general.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    barrier_to_general.dstAccessMask = VK_ACCESS_SHADER_WRITE_BIT;

    vk_context->vkCmdPipelineBarrier(cmd,
                                     VK_PIPELINE_STAGE_TRANSFER_BIT,
                                     VK_PIPELINE_STAGE_RAY_TRACING_SHADER_BIT_KHR,
                                     0, 0, nullptr, 0, nullptr, 1, &barrier_to_general);

    vk_context->vkEndCommandBuffer(cmd);

    // 7. Submit to GPU Queue with fence (ZERO vkQueueWaitIdle!)
    VkSubmitInfo submit_info;
    memset(&submit_info, 0, sizeof(submit_info));
    submit_info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &cmd;
    vk_context->vkQueueSubmit(vk_context->queue, 1, &submit_info, frame.fence);

    frame.has_rendered = true;
    current_frame = (current_frame + 1) % MAX_FRAMES_IN_FLIGHT;
}

Ref<ImageTexture> VoxelRayTracer::get_output_texture() {
    return output_texture;
}

Ref<Image> VoxelRayTracer::get_output_image() {
    return output_image;
}

} // namespace godot
