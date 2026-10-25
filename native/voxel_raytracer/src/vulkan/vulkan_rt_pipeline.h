#pragma once

#include "vulkan_context.h"
#include <vector>

namespace godot {

class VulkanRayTracingPipeline {
public:
    VulkanContext* ctx = nullptr;

    VkDescriptorSetLayout descriptor_set_layout = VK_NULL_HANDLE;
    VkPipelineLayout pipeline_layout = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;

    // Shader Binding Table (SBT) Buffer & Regions
    VkBuffer sbt_buffer = VK_NULL_HANDLE;
    VkDeviceMemory sbt_memory = VK_NULL_HANDLE;
    VkDeviceAddress sbt_address = 0;

    VkStridedDeviceAddressRegionKHR raygen_region = {};
    VkStridedDeviceAddressRegionKHR miss_region = {};
    VkStridedDeviceAddressRegionKHR hit_region = {};
    VkStridedDeviceAddressRegionKHR callable_region = {};

    VulkanRayTracingPipeline();
    ~VulkanRayTracingPipeline();

    bool init(VulkanContext* p_ctx,
              const uint32_t* rgen_spv, size_t rgen_size,
              const uint32_t* rmiss_spv, size_t rmiss_size,
              const uint32_t* rint_spv, size_t rint_size,
              const uint32_t* rchit_spv, size_t rchit_size);

    void cleanup();

private:
    VkShaderModule create_shader_module(const uint32_t* code, size_t size_bytes);
    bool create_sbt();
};

} // namespace godot
