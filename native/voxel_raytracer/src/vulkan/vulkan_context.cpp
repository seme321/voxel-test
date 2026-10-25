#include "vulkan_context.h"
#include <godot_cpp/variant/utility_functions.hpp>
#include <cstring>

namespace godot {

VulkanContext::VulkanContext() {
}

VulkanContext::~VulkanContext() {
    cleanup();
}

bool VulkanContext::load_vulkan_library() {
    UtilityFunctions::print("[VulkanContext] Loading vulkan-1.dll from System32...");
    vulkan_module = LoadLibraryA("vulkan-1.dll");
    if (!vulkan_module) {
        UtilityFunctions::printerr("[VulkanContext] Failed to load vulkan-1.dll!");
        return false;
    }

    vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr)GetProcAddress(vulkan_module, "vkGetInstanceProcAddr");
    if (!vkGetInstanceProcAddr) {
        UtilityFunctions::printerr("[VulkanContext] Failed to locate vkGetInstanceProcAddr!");
        return false;
    }

    vkCreateInstance = (PFN_vkCreateInstance)vkGetInstanceProcAddr(VK_NULL_HANDLE, "vkCreateInstance");
    vkDestroyInstance = (PFN_vkDestroyInstance)vkGetInstanceProcAddr(VK_NULL_HANDLE, "vkDestroyInstance");
    vkEnumeratePhysicalDevices = (PFN_vkEnumeratePhysicalDevices)vkGetInstanceProcAddr(VK_NULL_HANDLE, "vkEnumeratePhysicalDevices");

    UtilityFunctions::print("[VulkanContext] vulkan-1.dll loaded successfully.");
    return vkCreateInstance != nullptr;
}

bool VulkanContext::create_instance() {
    UtilityFunctions::print("[VulkanContext] Creating VkInstance...");
    VkApplicationInfo app_info;
    memset(&app_info, 0, sizeof(app_info));
    app_info.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app_info.pApplicationName = "Godot Voxel Raytracer";
    app_info.applicationVersion = VK_MAKE_VERSION(1, 0, 0);
    app_info.pEngineName = "Godot Engine";
    app_info.engineVersion = VK_MAKE_VERSION(4, 7, 0);
    app_info.apiVersion = VK_API_VERSION_1_3;

    VkInstanceCreateInfo create_info;
    memset(&create_info, 0, sizeof(create_info));
    create_info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    create_info.pApplicationInfo = &app_info;

    VkResult res = vkCreateInstance(&create_info, nullptr, &instance);
    if (res != VK_SUCCESS || instance == VK_NULL_HANDLE) {
        UtilityFunctions::printerr("[VulkanContext] vkCreateInstance failed with code: ", (int)res);
        return false;
    }
    UtilityFunctions::print("[VulkanContext] VkInstance created.");

    // Load instance-level functions
    #define LOAD_INST_FN(name) name = (PFN_##name)vkGetInstanceProcAddr(instance, #name); if (!name) { UtilityFunctions::printerr("[VulkanContext] Missing instance fn: " #name); return false; }
    LOAD_INST_FN(vkDestroyInstance);
    LOAD_INST_FN(vkEnumeratePhysicalDevices);
    LOAD_INST_FN(vkGetPhysicalDeviceProperties);
    LOAD_INST_FN(vkGetPhysicalDeviceProperties2);
    LOAD_INST_FN(vkGetPhysicalDeviceFeatures2);
    LOAD_INST_FN(vkGetPhysicalDeviceQueueFamilyProperties);
    LOAD_INST_FN(vkGetPhysicalDeviceMemoryProperties);
    LOAD_INST_FN(vkEnumerateDeviceExtensionProperties);
    LOAD_INST_FN(vkCreateDevice);
    LOAD_INST_FN(vkGetDeviceProcAddr);
    #undef LOAD_INST_FN

    UtilityFunctions::print("[VulkanContext] Instance functions loaded.");
    return true;
}

bool VulkanContext::select_physical_device() {
    UtilityFunctions::print("[VulkanContext] Enumerating physical devices...");
    uint32_t device_count = 0;
    vkEnumeratePhysicalDevices(instance, &device_count, nullptr);
    if (device_count == 0) {
        UtilityFunctions::printerr("[VulkanContext] No Vulkan physical devices found!");
        return false;
    }

    std::vector<VkPhysicalDevice> devices(device_count);
    vkEnumeratePhysicalDevices(instance, &device_count, devices.data());
    UtilityFunctions::print("[VulkanContext] Found ", (int)device_count, " physical device(s).");

    VkPhysicalDevice best_device = VK_NULL_HANDLE;

    for (const auto &dev : devices) {
        VkPhysicalDeviceProperties props;
        vkGetPhysicalDeviceProperties(dev, &props);
        UtilityFunctions::print("[VulkanContext] Testing device: ", props.deviceName);

        // Check required extensions
        uint32_t ext_count = 0;
        vkEnumerateDeviceExtensionProperties(dev, nullptr, &ext_count, nullptr);
        std::vector<VkExtensionProperties> extensions(ext_count);
        vkEnumerateDeviceExtensionProperties(dev, nullptr, &ext_count, extensions.data());

        bool has_accel = false;
        bool has_pipeline = false;
        bool has_deferred = false;
        bool has_bda = false;

        for (const auto &ext : extensions) {
            if (strcmp(ext.extensionName, VK_KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME) == 0) has_accel = true;
            if (strcmp(ext.extensionName, VK_KHR_RAY_TRACING_PIPELINE_EXTENSION_NAME) == 0) has_pipeline = true;
            if (strcmp(ext.extensionName, VK_KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME) == 0) has_deferred = true;
            if (strcmp(ext.extensionName, VK_KHR_BUFFER_DEVICE_ADDRESS_EXTENSION_NAME) == 0) has_bda = true;
        }

        bool supports_rt = has_accel && has_pipeline && has_deferred && has_bda;
        UtilityFunctions::print("[VulkanContext] RT Support: ", supports_rt, " (accel: ", has_accel, ", pipe: ", has_pipeline, ", bda: ", has_bda, ")");

        if (props.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU && supports_rt) {
            best_device = dev;
            device_name = props.deviceName;
            rtx_supported = true;
            break;
        } else if (supports_rt && best_device == VK_NULL_HANDLE) {
            best_device = dev;
            device_name = props.deviceName;
            rtx_supported = true;
        }
    }

    if (best_device == VK_NULL_HANDLE) {
        UtilityFunctions::printerr("[VulkanContext] No physical device with Vulkan Ray Tracing KHR extensions found!");
        return false;
    }

    physical_device = best_device;

    // Query RT Pipeline Properties
    VkPhysicalDeviceRayTracingPipelinePropertiesKHR rt_props;
    memset(&rt_props, 0, sizeof(rt_props));
    rt_props.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RAY_TRACING_PIPELINE_PROPERTIES_KHR;

    VkPhysicalDeviceProperties2 props2;
    memset(&props2, 0, sizeof(props2));
    props2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
    props2.pNext = &rt_props;

    vkGetPhysicalDeviceProperties2(physical_device, &props2);

    sbt_handle_size = rt_props.shaderGroupHandleSize;
    sbt_handle_alignment = rt_props.shaderGroupHandleAlignment;
    sbt_base_alignment = rt_props.shaderGroupBaseAlignment;

    // Find queue family supporting graphics/compute
    uint32_t q_family_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &q_family_count, nullptr);
    std::vector<VkQueueFamilyProperties> q_families(q_family_count);
    vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &q_family_count, q_families.data());

    for (uint32_t i = 0; i < q_family_count; ++i) {
        if ((q_families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && (q_families[i].queueFlags & VK_QUEUE_COMPUTE_BIT)) {
            queue_family_index = i;
            break;
        }
    }

    UtilityFunctions::print("[VulkanContext] Selected GPU: ", device_name.c_str(), " (SBT Handle: ", sbt_handle_size, "B, Align: ", sbt_handle_alignment, "B)");
    return true;
}

bool VulkanContext::create_logical_device() {
    UtilityFunctions::print("[VulkanContext] Creating logical VkDevice with Ray Tracing extensions...");
    float queue_priority = 1.0f;
    VkDeviceQueueCreateInfo queue_info;
    memset(&queue_info, 0, sizeof(queue_info));
    queue_info.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queue_info.queueFamilyIndex = queue_family_index;
    queue_info.queueCount = 1;
    queue_info.pQueuePriorities = &queue_priority;

    const std::vector<const char*> enabled_extensions = {
        VK_KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME,
        VK_KHR_RAY_TRACING_PIPELINE_EXTENSION_NAME,
        VK_KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME,
        VK_KHR_BUFFER_DEVICE_ADDRESS_EXTENSION_NAME,
        VK_KHR_SPIRV_1_4_EXTENSION_NAME,
        VK_KHR_SHADER_FLOAT_CONTROLS_EXTENSION_NAME
    };

    // Chain Ray Tracing Features
    VkPhysicalDeviceBufferDeviceAddressFeatures bda_features;
    memset(&bda_features, 0, sizeof(bda_features));
    bda_features.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_BUFFER_DEVICE_ADDRESS_FEATURES;
    bda_features.bufferDeviceAddress = VK_TRUE;

    VkPhysicalDeviceAccelerationStructureFeaturesKHR as_features;
    memset(&as_features, 0, sizeof(as_features));
    as_features.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR;
    as_features.accelerationStructure = VK_TRUE;
    as_features.pNext = &bda_features;

    VkPhysicalDeviceRayTracingPipelineFeaturesKHR rt_features;
    memset(&rt_features, 0, sizeof(rt_features));
    rt_features.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RAY_TRACING_PIPELINE_FEATURES_KHR;
    rt_features.rayTracingPipeline = VK_TRUE;
    rt_features.pNext = &as_features;

    VkPhysicalDeviceFeatures2 features2;
    memset(&features2, 0, sizeof(features2));
    features2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    features2.pNext = &rt_features;

    VkDeviceCreateInfo device_info;
    memset(&device_info, 0, sizeof(device_info));
    device_info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    device_info.pNext = &features2;
    device_info.queueCreateInfoCount = 1;
    device_info.pQueueCreateInfos = &queue_info;
    device_info.enabledExtensionCount = static_cast<uint32_t>(enabled_extensions.size());
    device_info.ppEnabledExtensionNames = enabled_extensions.data();

    VkResult res = vkCreateDevice(physical_device, &device_info, nullptr, &device);
    if (res != VK_SUCCESS || device == VK_NULL_HANDLE) {
        UtilityFunctions::printerr("[VulkanContext] vkCreateDevice with Hardware RT failed with code: ", (int)res);
        return false;
    }
    UtilityFunctions::print("[VulkanContext] Logical device created. Loading device function pointers...");

    if (!load_device_functions()) {
        UtilityFunctions::printerr("[VulkanContext] Failed to load Vulkan device function pointers!");
        return false;
    }

    vkGetDeviceQueue(device, queue_family_index, 0, &queue);

    // Create Command Pool
    VkCommandPoolCreateInfo pool_info;
    memset(&pool_info, 0, sizeof(pool_info));
    pool_info.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool_info.queueFamilyIndex = queue_family_index;
    pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;

    res = vkCreateCommandPool(device, &pool_info, nullptr, &command_pool);
    if (res != VK_SUCCESS) {
        UtilityFunctions::printerr("[VulkanContext] vkCreateCommandPool failed with code: ", (int)res);
        return false;
    }

    UtilityFunctions::print("[VulkanContext] Dedicated Vulkan Ray Tracing Device created successfully!");
    return true;
}

bool VulkanContext::load_device_functions() {
    #define LOAD_DEV_FN(name) name = (PFN_##name)vkGetDeviceProcAddr(device, #name); if (!name) { UtilityFunctions::printerr("[VulkanContext] Missing function: " #name); return false; }
    LOAD_DEV_FN(vkDestroyDevice);
    LOAD_DEV_FN(vkGetDeviceQueue);
    LOAD_DEV_FN(vkCreateCommandPool);
    LOAD_DEV_FN(vkDestroyCommandPool);
    LOAD_DEV_FN(vkAllocateCommandBuffers);
    LOAD_DEV_FN(vkFreeCommandBuffers);
    LOAD_DEV_FN(vkBeginCommandBuffer);
    LOAD_DEV_FN(vkEndCommandBuffer);
    LOAD_DEV_FN(vkQueueSubmit);
    LOAD_DEV_FN(vkQueueWaitIdle);
    LOAD_DEV_FN(vkDeviceWaitIdle);

    LOAD_DEV_FN(vkCreateBuffer);
    LOAD_DEV_FN(vkDestroyBuffer);
    LOAD_DEV_FN(vkGetBufferMemoryRequirements);
    LOAD_DEV_FN(vkAllocateMemory);
    LOAD_DEV_FN(vkFreeMemory);
    LOAD_DEV_FN(vkBindBufferMemory);
    LOAD_DEV_FN(vkMapMemory);
    LOAD_DEV_FN(vkUnmapMemory);
    LOAD_DEV_FN(vkGetBufferDeviceAddressKHR);

    LOAD_DEV_FN(vkCreateImage);
    LOAD_DEV_FN(vkDestroyImage);
    LOAD_DEV_FN(vkGetImageMemoryRequirements);
    LOAD_DEV_FN(vkBindImageMemory);
    LOAD_DEV_FN(vkCreateImageView);
    LOAD_DEV_FN(vkDestroyImageView);
    LOAD_DEV_FN(vkCmdPipelineBarrier);
    LOAD_DEV_FN(vkCmdCopyImageToBuffer);
    LOAD_DEV_FN(vkCmdCopyBufferToImage);

    LOAD_DEV_FN(vkCreateDescriptorSetLayout);
    LOAD_DEV_FN(vkDestroyDescriptorSetLayout);
    LOAD_DEV_FN(vkCreateDescriptorPool);
    LOAD_DEV_FN(vkDestroyDescriptorPool);
    LOAD_DEV_FN(vkAllocateDescriptorSets);
    LOAD_DEV_FN(vkUpdateDescriptorSets);
    LOAD_DEV_FN(vkCreatePipelineLayout);
    LOAD_DEV_FN(vkDestroyPipelineLayout);

    // RT Extensions
    LOAD_DEV_FN(vkCreateAccelerationStructureKHR);
    LOAD_DEV_FN(vkDestroyAccelerationStructureKHR);
    LOAD_DEV_FN(vkCmdBuildAccelerationStructuresKHR);
    LOAD_DEV_FN(vkGetAccelerationStructureBuildSizesKHR);
    LOAD_DEV_FN(vkGetAccelerationStructureDeviceAddressKHR);
    LOAD_DEV_FN(vkCreateRayTracingPipelinesKHR);
    LOAD_DEV_FN(vkGetRayTracingShaderGroupHandlesKHR);
    LOAD_DEV_FN(vkCmdTraceRaysKHR);
    #undef LOAD_DEV_FN

    return true;
}

uint32_t VulkanContext::find_memory_type(uint32_t type_filter, VkMemoryPropertyFlags properties) const {
    VkPhysicalDeviceMemoryProperties mem_props;
    vkGetPhysicalDeviceMemoryProperties(physical_device, &mem_props);

    for (uint32_t i = 0; i < mem_props.memoryTypeCount; i++) {
        if ((type_filter & (1 << i)) && (mem_props.memoryTypes[i].propertyFlags & properties) == properties) {
            return i;
        }
    }
    return 0;
}

VkDeviceAddress VulkanContext::get_buffer_address(VkBuffer buffer) const {
    if (!vkGetBufferDeviceAddressKHR || !device || !buffer) return 0;
    VkBufferDeviceAddressInfoKHR info = { VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO_KHR };
    info.buffer = buffer;
    return vkGetBufferDeviceAddressKHR(device, &info);
}

bool VulkanContext::init() {
    if (!load_vulkan_library()) return false;
    if (!create_instance()) return false;
    if (!select_physical_device()) return false;
    if (!create_logical_device()) return false;
    return true;
}

void VulkanContext::cleanup() {
    if (device != VK_NULL_HANDLE) {
        if (vkDeviceWaitIdle) vkDeviceWaitIdle(device);
        if (command_pool != VK_NULL_HANDLE && vkDestroyCommandPool) {
            vkDestroyCommandPool(device, command_pool, nullptr);
            command_pool = VK_NULL_HANDLE;
        }
        if (vkDestroyDevice) {
            vkDestroyDevice(device, nullptr);
            device = VK_NULL_HANDLE;
        }
    }

    if (instance != VK_NULL_HANDLE && vkDestroyInstance) {
        vkDestroyInstance(instance, nullptr);
        instance = VK_NULL_HANDLE;
    }

    if (vulkan_module != nullptr) {
        FreeLibrary(vulkan_module);
        vulkan_module = nullptr;
    }

    rtx_supported = false;
}

} // namespace godot
