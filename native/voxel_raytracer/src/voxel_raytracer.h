#pragma once

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/vector3i.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/string.hpp>

#include "vulkan/vulkan_context.h"
#include "vulkan/vulkan_rt_pipeline.h"

#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace godot {

class VoxelRayTracer : public Node3D {
    GDCLASS(VoxelRayTracer, Node3D)

private:
    int render_width = 1280;
    int render_height = 720;
    int ray_bounces = 1;
    bool is_initialized = false;
    bool rtx_available = false;
    String gpu_device_name = "Detecting...";

    std::unique_ptr<VulkanContext> vk_context;
    std::unique_ptr<VulkanRayTracingPipeline> rt_pipeline;

    Ref<Image> output_image;
    Ref<ImageTexture> output_texture;

    // Sector registration tracking
    struct SectorData {
        Vector3i pos;
        PackedByteArray aabbs;
        PackedByteArray bricks;
    };
    std::unordered_map<int64_t, SectorData> active_sectors;

    int64_t get_sector_key(const Vector3i &p_pos) const {
        return ((int64_t)(p_pos.x & 0x1FFFFF)) |
               (((int64_t)(p_pos.y & 0x1FFFFF)) << 21) |
               (((int64_t)(p_pos.z & 0x1FFFFF)) << 42);
    }

protected:
    static void _bind_methods();

public:
    VoxelRayTracer();
    ~VoxelRayTracer();

    // Diagnostics & Capabilities
    bool is_rtx_supported() const;
    String get_gpu_name() const;
    String get_raytracer_status() const;

    // Initialization & Config
    bool init_raytracer(int p_width, int p_height);
    void set_render_width(int p_width);
    int get_render_width() const;
    void set_render_height(int p_height);
    int get_render_height() const;
    void set_ray_bounces(int p_bounces);
    int get_ray_bounces() const;

    // Sector Geometry Stream
    void upload_sector_aabbs(const Vector3i &p_pos, const PackedByteArray &p_aabbs);
    void upload_sector_bricks(const Vector3i &p_pos, const PackedByteArray &p_bricks);
    void remove_sector(const Vector3i &p_pos);
    int get_active_sector_count() const;

    // Render & Presentation
    void render_frame(const Transform3D &p_cam_transform, float p_fov);
    Ref<ImageTexture> get_output_texture();
};

} // namespace godot
