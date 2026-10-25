#include "voxel_raytracer.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

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
    ClassDB::bind_method(D_METHOD("remove_sector", "sector_pos"), &VoxelRayTracer::remove_sector);
    ClassDB::bind_method(D_METHOD("get_active_sector_count"), &VoxelRayTracer::get_active_sector_count);

    // Execution & Presentation
    ClassDB::bind_method(D_METHOD("render_frame", "camera_transform", "fov"), &VoxelRayTracer::render_frame);
    ClassDB::bind_method(D_METHOD("get_output_texture"), &VoxelRayTracer::get_output_texture);
}

VoxelRayTracer::VoxelRayTracer() {
    UtilityFunctions::print("[VoxelRayTracer] Instantiating Native C++ GDExtension Ray Tracer...");
}

VoxelRayTracer::~VoxelRayTracer() {
    active_sectors.clear();
    output_image.unref();
    output_texture.unref();
    if (vk_context) {
        vk_context->cleanup();
        vk_context.reset();
    }
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
    return String("Ready (Hardware RT Active) | GPU: ") + vk_context->device_name.c_str() +
           " | SBT Handle: " + String::num_int64(vk_context->sbt_handle_size) + "B" +
           " | Sectors: " + String::num_int64(active_sectors.size()) +
           " | Resolution: " + String::num_int64(render_width) + "x" + String::num_int64(render_height);
}

bool VoxelRayTracer::init_raytracer(int p_width, int p_height) {
    if (p_width <= 0 || p_height <= 0) {
        UtilityFunctions::printerr("[VoxelRayTracer] Invalid dimensions: ", p_width, "x", p_height);
        return false;
    }

    render_width = p_width;
    render_height = p_height;

    // Initialize Vulkan Ray Tracing Context
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

    // Create presentation texture buffer
    output_image = Image::create_empty(render_width, render_height, false, Image::FORMAT_RGBA8);
    output_texture = ImageTexture::create_from_image(output_image);

    is_initialized = true;
    UtilityFunctions::print("[VoxelRayTracer] Hardware Ray Tracer initialized successfully on: ", gpu_device_name, " at ", render_width, "x", render_height);
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
    auto it = active_sectors.find(key);
    if (it == active_sectors.end()) {
        SectorData data;
        data.pos = p_pos;
        data.aabbs = p_aabbs;
        active_sectors[key] = data;
    } else {
        it->second.aabbs = p_aabbs;
    }
}

void VoxelRayTracer::upload_sector_bricks(const Vector3i &p_pos, const PackedByteArray &p_bricks) {
    int64_t key = get_sector_key(p_pos);
    auto it = active_sectors.find(key);
    if (it == active_sectors.end()) {
        SectorData data;
        data.pos = p_pos;
        data.bricks = p_bricks;
        active_sectors[key] = data;
    } else {
        it->second.bricks = p_bricks;
    }
}

void VoxelRayTracer::remove_sector(const Vector3i &p_pos) {
    int64_t key = get_sector_key(p_pos);
    active_sectors.erase(key);
}

int VoxelRayTracer::get_active_sector_count() const {
    return static_cast<int>(active_sectors.size());
}

void VoxelRayTracer::render_frame(const Transform3D &p_cam_transform, float p_fov) {
    if (!is_initialized || !vk_context || !vk_context->rtx_supported) {
        return;
    }
    // Execution will invoke Vulkan vkCmdTraceRaysKHR in Phase 4/5
}

Ref<ImageTexture> VoxelRayTracer::get_output_texture() {
    return output_texture;
}

} // namespace godot
