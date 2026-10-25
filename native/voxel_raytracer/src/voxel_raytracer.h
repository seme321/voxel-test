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
#include "vulkan/vulkan_as_manager.h"

#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace godot {

struct alignas(16) CameraParams {
    float viewInverse[16];
    float projInverse[16];
    float camPos[4];
    float fov;
    uint32_t width;
    uint32_t height;
    uint32_t frameIndex;
};

class VoxelRayTracer : public Node3D {
    GDCLASS(VoxelRayTracer, Node3D)

private:
    int render_width = 1280;
    int render_height = 720;
    int ray_bounces = 1;
    bool is_initialized = false;
    bool rtx_available = false;
    String gpu_device_name = "Detecting...";
    uint32_t frame_index = 0;
    bool tlas_dirty = true;

    std::unique_ptr<VulkanContext> vk_context;
    std::unique_ptr<VulkanRayTracingPipeline> rt_pipeline;
    std::unique_ptr<VulkanASManager> as_manager;

    // Vulkan Offscreen Output Target & Staging
    VkImage vk_render_target = VK_NULL_HANDLE;
    VkDeviceMemory vk_render_target_memory = VK_NULL_HANDLE;
    VkImageView vk_render_target_view = VK_NULL_HANDLE;
    VulkanBuffer camera_uniform_buffer;

    // Double Buffering Frames-in-Flight
    static const uint32_t MAX_FRAMES_IN_FLIGHT = 2;
    struct FrameSync {
        VkCommandBuffer command_buffer = VK_NULL_HANDLE;
        VkFence fence = VK_NULL_HANDLE;
        VulkanBuffer staging_output_buffer;
        bool has_rendered = false;
    };
    FrameSync frames[MAX_FRAMES_IN_FLIGHT];
    uint32_t current_frame = 0;

    // Descriptors
    VkDescriptorPool descriptor_pool = VK_NULL_HANDLE;
    VkDescriptorSet descriptor_set = VK_NULL_HANDLE;

    // Presentation image & texture
    Ref<Image> output_image;
    Ref<ImageTexture> output_texture;
    PackedByteArray output_pixel_buffer;

    // Sector staging
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

    bool init_render_targets();
    void cleanup_render_targets();
    bool update_descriptor_set();

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
    bool patch_sector_brick(const Vector3i &p_pos, int p_bindex, const PackedByteArray &p_brick_bytes);
    int get_active_sector_count() const;

    // Render & Presentation
    void render_frame(const Transform3D &p_cam_transform, float p_fov);
    Ref<ImageTexture> get_output_texture();
    Ref<Image> get_output_image();
};

} // namespace godot
