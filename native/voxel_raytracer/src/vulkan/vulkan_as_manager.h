#pragma once

#include "vulkan_context.h"
#include <godot_cpp/variant/vector3i.hpp>
#include <unordered_map>
#include <vector>

namespace godot {

struct VulkanBuffer {
    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkDeviceSize size = 0;
    VkDeviceAddress device_address = 0;
    void* mapped_ptr = nullptr;
};

struct SectorBLAS {
    Vector3i sector_pos;
    uint32_t aabb_count = 0;
    uint32_t brick_count = 0;
    std::vector<uint8_t> brick_data;
    VulkanBuffer aabb_buffer;
    VulkanBuffer blas_buffer;
    VkAccelerationStructureKHR blas = VK_NULL_HANDLE;
    VkDeviceAddress blas_address = 0;
    uint32_t global_brick_offset = 0;
    std::unordered_map<uint32_t, uint32_t> bindex_to_slot;
};

class VulkanASManager {
public:
    VulkanContext* ctx = nullptr;

    std::unordered_map<int64_t, SectorBLAS> sectors;

    // Top Level Acceleration Structure (TLAS)
    VulkanBuffer tlas_instance_buffer;
    VulkanBuffer tlas_buffer;
    VkAccelerationStructureKHR tlas = VK_NULL_HANDLE;
    VkDeviceAddress tlas_address = 0;

    // Unified Brick Buffer for ray tracing intersection
    VulkanBuffer global_brick_buffer;
    uint32_t total_active_bricks = 0;

    // Shared Reusable Scratch Buffer
    VulkanBuffer scratch_buffer;
    VkDeviceSize current_scratch_size = 0;

    VulkanASManager();
    ~VulkanASManager();

    bool init(VulkanContext* p_ctx);
    void cleanup();

    // BLAS Management
    bool build_sector_blas(const Vector3i& p_pos,
                           uint32_t p_aabb_count, const void* p_aabb_data,
                           uint32_t p_brick_count, const void* p_brick_data);
    void remove_sector_blas(const Vector3i& p_pos);
    bool patch_sector_brick(const Vector3i& p_pos, uint32_t p_bindex, const void* p_brick_1096);

    // TLAS Management
    bool build_tlas();

    VkAccelerationStructureKHR get_tlas() const { return tlas; }
    VkBuffer get_global_brick_buffer() const { return global_brick_buffer.buffer; }
    VkDeviceSize get_global_brick_buffer_size() const { return global_brick_buffer.size; }
    uint32_t get_sector_count() const { return static_cast<uint32_t>(sectors.size()); }

    // Buffer helpers
    bool create_buffer(VkDeviceSize size, VkBufferUsageFlags usage, VkMemoryPropertyFlags mem_props, VulkanBuffer& out_buf);
    void destroy_buffer(VulkanBuffer& buf);
    VkCommandBuffer begin_single_time_commands();
    void end_single_time_commands(VkCommandBuffer cmd);

private:
    int64_t get_sector_key(const Vector3i& p_pos) const {
        return ((int64_t)(p_pos.x & 0x1FFFFF)) |
               (((int64_t)(p_pos.y & 0x1FFFFF)) << 21) |
               (((int64_t)(p_pos.z & 0x1FFFFF)) << 42);
    }

    bool ensure_scratch_buffer(VkDeviceSize required_size);
};

} // namespace godot
