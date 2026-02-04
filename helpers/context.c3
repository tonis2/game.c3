module helpers;

import vk;
import stb;
import c3w;

import std::math;
import std::io;
import std::collections::list;
import std::collections::map;
import std::encoding::json;
import gltf;

alias Vec2f = float[<2>];
alias Vec3f = float[<3>];

alias Vec4f = float[<4>];
// fn usz? Vec4f.to_format(&self, Formatter* formatter) @dynamic => formatter.printf("%f,%f,%f", self.x, self.y, self.z)!;

const MAX_FRAMES_IN_FLIGHT = 2;

faultdef NO_SUITABLE_DEVICE, FILE_NOT_FOUND;

alias DescriptorImages = List{DescriptorImageInfo};

struct DeviceContext {
    Instance instance;
    Device device;
    PhysicalDevice pdevice;
    SwapchainKHR swapchain;
    ImageViewList swapchain_views;
    ImageList swapchain_images;
    CommandPool command_pool;
    CommandBufferList command_buffers;
    DeviceQueue graphics_queue;
    Format depth_format;
    SurfaceFormatKHR surface_format;
    Extent2D extent;
    SurfaceKHR surface;

    vk::Allocator allocator;
    SemaphoreList wait_semaphores;
    SemaphoreList signal_semaphores;
    FenceList frame_fences;
    uint frame;
}

struct PipelineLayer {
    DescriptorSetLayout descriptor_layout;
    PipelineLayout layout;
    List{WriteDescriptorSet} sets;
}

fn void DeviceContext.free(self) {
    self.device.waitIdle();
    foreach (view : self.swapchain_views) view.free(self.device);
    self.swapchain.free(self.device);

    self.swapchain_images.free();
    self.swapchain_views.free();
    self.command_pool.free(self.device);
    self.command_buffers.free();
    self.surface.free(self.instance);

    self.wait_semaphores.release(self.device);
    self.signal_semaphores.release(self.device);
    self.frame_fences.release(self.device);

    self.allocator.free();
    self.device.free();
    self.instance.free();
}

fn uint? DeviceContext.next_image(self) {
    Fence frame_fence = self.frame_fences[self.frame];
    Semaphore wait_semaphore = self.wait_semaphores[self.frame];
    
    vk::waitForFences(self.device, 1, &frame_fence, vk::TRUE, uint.max)!;
    vk::resetFences(self.device, 1, &frame_fence)!;

    return self.swapchain.getNextImage(self.device, wait_semaphore);
}

fn void? DeviceContext.present_image(&self, uint next_image, CommandBuffer command_buffer) {
    Semaphore wait_semaphore = self.wait_semaphores[self.frame];
    Semaphore signal_semaphore = self.signal_semaphores[next_image];
    Fence frame_fence = self.frame_fences[self.frame];

    SubmitInfo submit_info = vk::submitInfo()
    .setWaitSemaphores({ wait_semaphore })
    .setCommandBuffers({ command_buffer })
    .setSignalSemaphores({ signal_semaphore })
    .setWaitDstStageMask({ vk::PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT});

    vk::queueSubmit(self.graphics_queue.handle, 1, &submit_info, frame_fence)!;

    PresentInfoKHR present_info = vk::presentInfoKHR()
    .setWaitSemaphores({ signal_semaphore })
    .setSwapchains({ self.swapchain })
    .setImageIndices({ next_image });

    vk::queuePresentKHR(self.graphics_queue.handle, &present_info)!;

    self.frame = (self.frame + 1) % 2;
}

fn DeviceContext? createContext(c3w::Window win) {
 
    ZStringList extensions;
    ZStringList device_extensions;
    //"VK_EXT_dynamic_rendering_unused_attachments"
    device_extensions.push_all({"VK_KHR_swapchain", "VK_KHR_push_descriptor", "VK_EXT_extended_dynamic_state", "VK_EXT_extended_dynamic_state3", "VK_KHR_dynamic_rendering", "VK_KHR_shader_non_semantic_info"});
    extensions.push_all({"VK_KHR_surface"});

    Instance instance;
    PhysicalDevice physical_device;
    DeviceQueue graphics_queue;
    Device device;
    SurfaceKHR surface;

    if (env::OS_TYPE == MACOS) {
        extensions.push_all({"VK_EXT_metal_surface", "VK_KHR_portability_enumeration"});
        device_extensions.push("VK_KHR_portability_subset");
    }

    if (env::OS_TYPE == WIN32) {
        extensions.push_all({"VK_KHR_win32_surface"});
    }

    if (env::OS_TYPE == LINUX) {
        $if $feature(WAYLAND):
            extensions.push_all({"VK_KHR_wayland_surface"});
        $endif

        $if $feature(X11):
            extensions.push_all({"VK_KHR_xcb_surface"});
        $endif
    }

    vk::checkInstanceExtensionSupport(extensions)!!;

    ApplicationInfo info = {
      .pApplicationName = "TEST",
      .pEngineName = "Super engine",
      .applicationVersion = vk::@makeApiVersion(0,1,0,0),
      .engineVersion = vk::@makeApiVersion(0,1,0,0),
      .apiVersion = vk::@makeApiVersion(0,1,3,0)
    };

    InstanceCreateInfo instanceInfo = vk::instanceCreateInfo()
    .setApplicationInfo(&info)
    .setFlags(env::os_is_darwin() ? vk::INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0)
    .setEnabledExtensionNames(extensions.array_view());

    if (catch err = vk::createInstance(&instanceInfo, null, &instance)) {
        io::printfn("Extension error");
        return NO_SUITABLE_DEVICE~;
    }

    vk::loadExtensions(instance);

    // Create surface
    $switch(env::OS_TYPE):
        $case MACOS:
            MetalSurfaceCreateInfoEXT createInfo = {
                .sType = vk::STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
                .pLayer = (CAMetalLayer*)win.src.layer.id
            };

            vk::createMetalSurfaceEXT(instance, &createInfo, null, &surface)!!;
        $case LINUX: {
            $if $feature(WAYLAND):
                WaylandSurfaceCreateInfoKHR createInfo = {
                    vk::STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR, 
                    null, 
                    0, 
                    win.src.display,
                    win.src.surface,
                };
                vk::createWaylandSurfaceKHR(instance, &createInfo, null, &surface)!!;
            $endif

            $if $feature(X11):
                XcbSurfaceCreateInfoKHR createInfo = {
                    vk::STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR, 
                    null, 
                    0, 
                    win.src.connection,
                    (vk::Window)win.src.window,
                };
                vk::createXcbSurfaceKHR(instance, &createInfo, null, &surface)!!;
            $endif
        }
        $case WIN32: {
            Win32SurfaceCreateInfoKHR createInfo = {
                vk::STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
                null,
                0,
                win.src.instance,
                win.src.hwnd
            };
            vk::createWin32SurfaceKHR(instance, &createInfo, null, &surface)!!;
        }
        $default: {}
    $endswitch

    DeviceList devices = instance.getDevices()!!;

    uint best_score = 0;
    PhysicalDeviceProperties device_props;

    foreach (usz i, entry: devices) {
        int queue_index = -1;
        // Check for device extension support
        bool supports_extensions = entry.checkExtensionSupport(device_extensions)!!;
        QueuePropertiesList queue_properties = entry.getQueueProperties()!!;

        queue_index = queue_properties.find(fn (usz index, QueueFamilyProperties props) => 
        (QueueFlagBits)props.queueFlags & vk::QUEUE_GRAPHICS_BIT != 0 && (QueueFlagBits)props.queueFlags & vk::QUEUE_TRANSFER_BIT);

        PhysicalDeviceProperties properties;
        vk::getPhysicalDeviceProperties(entry, &properties);
        assert(surface.checkSurfaceSupport((usz)queue_index, entry)!!);
        
        if (queue_index >= 0 && supports_extensions && properties.vendorID != 0) {
            uint score = 0;
            if (properties.deviceType == 1) score += 100;
            if (properties.deviceType == 2) score += 200;

            if (score > best_score) {
                best_score = score;
                physical_device = entry;
                graphics_queue.index = queue_index;
                device_props = properties;
            }
        }
    }

    if (physical_device == null) {
        io::printfn("Found no suitable device");
        return NO_SUITABLE_DEVICE~;
    }

    io::printfn("Device selected %s", (ZString)device_props.deviceName[0..]);

    devices.free();

    // PhysicalDeviceDynamicRenderingUnusedAttachmentsFeaturesEXT unused_attchments = {
    //     .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_UNUSED_ATTACHMENTS_FEATURES_EXT,
    //     .pNext = null,
    //     .dynamicRenderingUnusedAttachments = vk::TRUE
    // };

    PhysicalDeviceExtendedDynamicState3PropertiesEXT dynamicProperties = {
        .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_3_PROPERTIES_EXT,
        .pNext = null,
        .dynamicPrimitiveTopologyUnrestricted = vk::TRUE
    };

    PhysicalDeviceExtendedDynamicState3FeaturesEXT dynamicState = {
        .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_3_FEATURES_EXT,
        .pNext = &dynamicProperties,
        .extendedDynamicState3ColorBlendEnable = vk::TRUE,
    };


    PhysicalDeviceVulkan13Features vulkan13Features = {
        .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .pNext = &dynamicState,
    };

    PhysicalDeviceVulkan12Features vulkan12Features = {
        .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
        .pNext = &vulkan13Features,
    };

    PhysicalDeviceVulkan11Features vulkan11Features = {
        .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
        .pNext = &vulkan12Features,
    };

    PhysicalDeviceFeatures2 device_features = {
        .sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        .pNext = &vulkan11Features,
    };

    vk::getPhysicalDeviceFeatures2(physical_device, &device_features);

    DeviceQueueCreateInfo graphicsInfo = vk::deviceQueueCreateInfo()
    .setQueueFamilyIndex(graphics_queue.index)
    .setQueuePriorities({1.0});

    device = vk::deviceCreateInfo()
        .setQueueCreateInfos({ graphicsInfo })
        .setEnabledExtensionNames(device_extensions.array_view())
        .setNext(&device_features)
        .build(physical_device)!!;


    graphics_queue.handle = device.getQueue(graphics_queue.index);

    SurfaceFormatList surface_formats = surface.getFormats(physical_device)!!;
    PresentModeList present_modes = surface.getPresentModes(physical_device)!!;
    SurfaceCapabilitiesKHR capabilities = surface.deviceSurfaceCapabilities(physical_device)!!;

	defer {
		surface_formats.free();
		present_modes.free();
	}

    vk::Format depth_format = vk::findDepthFormat(features: vk::FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT, device: physical_device);
    SurfaceFormatKHR format = {.format = vk::FORMAT_B8G8R8A8_UNORM, .colorSpace = vk::COLOR_SPACE_SRGB_NONLINEAR_KHR};

    uint min_images = capabilities.maxImageCount != 0 ? capabilities.maxImageCount : capabilities.minImageCount + 2;
    Extent2D extent = {(uint)win.width, (uint)win.height};;

    SwapchainCreateInfoKHR swapchain_info = vk::swapchainCreateInfoKHR()
        .setMinImageCount(min_images)
        .setImageUsage(vk::IMAGE_USAGE_COLOR_ATTACHMENT_BIT)
        .setImageSharingMode(vk::SHARING_MODE_EXCLUSIVE)
        .setCompositeAlpha(vk::COMPOSITE_ALPHA_OPAQUE_BIT_KHR)
        .setPresentMode(vk::PRESENT_MODE_FIFO_KHR)
        .setPreTransform(capabilities.currentTransform)
        .setImageColorSpace(format.colorSpace)
        .setImageFormat(format.format)
        .setSurface(surface)
        .setImageArrayLayers(1)
        .setImageExtent(extent);

    SwapchainKHR swapchain = swapchain_info.build(device)!!;
    vk::ImageList swapchain_images = swapchain.getImages(device, swapchain_info.minImageCount)!!;

    ImageViewList swapchain_views;

    for (int i = 0; i < swapchain_info.minImageCount; ++i) {
        ImageView view = vk::imageViewCreateInfo()
        .setViewType(vk::IMAGE_VIEW_TYPE_2D)
        .setFormat(format.format)
        .setComponents({
            .r = vk::COMPONENT_SWIZZLE_IDENTITY,
            .g = vk::COMPONENT_SWIZZLE_IDENTITY,
            .b = vk::COMPONENT_SWIZZLE_IDENTITY,
            .a = vk::COMPONENT_SWIZZLE_IDENTITY,
        })
        .setSubresourceRange({
            .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
            .levelCount = 1,
        })
        .setImage(swapchain_images[i])
        .build(device)!!;

        swapchain_views.push(view);
    }

    CommandPool command_pool = device.createCommandPool(queue: graphics_queue.index)!;
    CommandBufferList command_buffers = device.createCommandBuffers(command_pool, swapchain_info.minImageCount)!;

    SemaphoreList wait_semaphores;
    SemaphoreList signal_semaphores;
    FenceList frame_fences;

    for (uint i = 0; i < swapchain_info.minImageCount; ++i) {
        wait_semaphores.push(vk::semaphoreCreateInfo().build(device))!;
        signal_semaphores.push(vk::semaphoreCreateInfo().build(device))!;
        frame_fences.push(vk::fenceCreateInfo().setFlags(vk::FENCE_CREATE_SIGNALED_BIT).build(device))!;
    }

	// Single allocator manages everything
    vk::Allocator allocator = (vk::Allocator){
        .device = device,
        .pdevice = physical_device,
        .queue = &graphics_queue,
        .flags = vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT | vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_CAPTURE_REPLAY_BIT,
    }.init()!;

    return (DeviceContext) {
        .instance = instance,
        .device = device,
        .pdevice = physical_device,
        .swapchain = swapchain,
        .swapchain_views = swapchain_views,
        .swapchain_images = swapchain_images,
        .command_pool = command_pool,
        .command_buffers = command_buffers,
        .graphics_queue = graphics_queue,
        .depth_format = depth_format,
        .surface_format = format,
        .extent = extent,
        .surface = surface,
        .wait_semaphores = wait_semaphores,
        .signal_semaphores = signal_semaphores,
        .frame_fences = frame_fences,
		.allocator = allocator
    };
}

fn void? DescriptorImages.addImageTexture(&self, stb::Image image_data, DeviceContext* context) {
    vk::Device device = context.device;
    vk::PhysicalDevice pdevice = context.pdevice;

    DeviceQueue graphics_queue = context.graphics_queue;

     vk::Allocator* allocator = &context.allocator;

    Format image_format = vk::FORMAT_R8G8B8A8_UNORM;
    DescriptorImageInfo texture = { .imageLayout = vk::IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };

    vk::Image texture_image = vk::imageCreateInfo()
        .setImageType(vk::IMAGE_TYPE_2D)
        .setExtent({.width = image_data.width, .height = image_data.height, .depth = 1 })
        .setMipLevels(1)
        .setArrayLayers(1)
        .setSamples(vk::SAMPLE_COUNT_1_BIT)
        .setUsage(vk::IMAGE_USAGE_TRANSFER_DST_BIT | vk::IMAGE_USAGE_SAMPLED_BIT)
        .setInitialLayout(vk::IMAGE_LAYOUT_UNDEFINED)
        .setTiling(vk::IMAGE_TILING_OPTIMAL)
        .setFormat(image_format)
        .build(device)!;

    vk::create_image_buffer(texture_image, allocator, properties: vk::MEMORY_PROPERTY_DEVICE_LOCAL_BIT)!;

    texture.sampler = vk::samplerCreateInfo()
            .setMagFilter(vk::FILTER_NEAREST)
            .setMinFilter(vk::FILTER_NEAREST)
            .setAddressModeU(vk::SAMPLER_ADDRESS_MODE_REPEAT)
            .setAddressModeV(vk::SAMPLER_ADDRESS_MODE_REPEAT)
            .setAddressModeW(vk::SAMPLER_ADDRESS_MODE_REPEAT)
            .setMipLodBias(0.0)
            .setMinLod(0.0)
            .setMaxLod(1.0)
            .setMaxAnisotropy(1.0)
            .setAnisotropyEnable(vk::FALSE)
            .setBorderColor(vk::BORDER_COLOR_FLOAT_OPAQUE_WHITE)
            .build(device)!;

    texture.imageView = vk::imageViewCreateInfo()
            .setViewType(vk::IMAGE_VIEW_TYPE_2D)
            .setFormat(image_format)
            .setComponents({
                .r = vk::COMPONENT_SWIZZLE_R,
                .g = vk::COMPONENT_SWIZZLE_G,
                .b = vk::COMPONENT_SWIZZLE_B,
                .a = vk::COMPONENT_SWIZZLE_A,
            })
            .setSubresourceRange({
                .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
                .levelCount = 1,
            })
            .setImage(texture_image)
            .build(device)!;

	Memory stage_buffer = vk::new_buffer(
		allocator: allocator,
        usage: vk::BUFFER_USAGE_TRANSFER_SRC_BIT,
        properties: vk::MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk::MEMORY_PROPERTY_HOST_CACHED_BIT,
        data: image_data.pixels,
        data_size: (usz)image_data.width * image_data.height * 4
    )!!;

    defer stage_buffer.free();

    vk::ImageMemoryBarrier2 transfer_barrier = {
        .sType = vk::STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = vk::PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        .dstStageMask = vk::PIPELINE_STAGE_TRANSFER_BIT,
        .srcAccessMask = 0,
        .dstAccessMask = vk::ACCESS_2_TRANSFER_WRITE_BIT,
        .image = texture_image,
        .oldLayout = vk::IMAGE_LAYOUT_UNDEFINED,
        .newLayout = vk::IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .subresourceRange = {
            .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        }
    };

    vk::ImageMemoryBarrier2 finalize_barrier = {
        .sType = vk::STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = vk::PIPELINE_STAGE_TRANSFER_BIT,
        .dstStageMask = vk::PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        .srcAccessMask = vk::ACCESS_2_TRANSFER_WRITE_BIT,
        .dstAccessMask = vk::ACCESS_2_SHADER_READ_BIT,
        .image = texture_image,
        .oldLayout = vk::IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .newLayout = vk::IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        .subresourceRange = {
            .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        }
    };

    device.@single_time_command(queue: context.graphics_queue; CommandBuffer command_buffer) {
        
        vk::cmdPipelineBarrier2(command_buffer, &&vk::dependencyInfo()
        .setImageMemoryBarriers({ transfer_barrier }));

        BufferImageCopy bufferCopyRegion = {
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = {
                .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = {0, 0, 0},
            .imageExtent = {.width = image_data.width, .height = image_data.height, .depth = 1 }
        };

        vk::cmdCopyBufferToImage(
            command_buffer,
            stage_buffer.buffer,
            texture_image,
            vk::IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &bufferCopyRegion
        );

        vk::cmdPipelineBarrier2(command_buffer, &&vk::dependencyInfo()
        .setImageMemoryBarriers({ finalize_barrier }));
    }!;

    self.push(texture);
}

fn vk::Image? DescriptorImages.addDepthTexture(&self, vk::Allocator* allocator, DeviceQueue queue, Vec2f size, vk::Format format) {
    DescriptorImageInfo texture;

    vk::Device device = allocator.device;
    vk::PhysicalDevice pdevice = allocator.pdevice; 

    texture.imageLayout = vk::IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;

    vk::Image depth_image = vk::imageCreateInfo()
    .setImageType(vk::IMAGE_TYPE_2D)
    .setExtent({.width = (uint)size.x, .height = (uint)size.y, .depth = 1 })
    .setMipLevels(1)
    .setArrayLayers(1)
    .setSamples(vk::SAMPLE_COUNT_1_BIT)
    .setUsage(vk::IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | vk::IMAGE_USAGE_SAMPLED_BIT)
    .setInitialLayout(vk::IMAGE_LAYOUT_UNDEFINED)
    .setTiling(vk::IMAGE_TILING_OPTIMAL)
    .setFormat(format)
    .build(device)!;

    vk::create_image_buffer(depth_image, allocator, properties: vk::MEMORY_PROPERTY_DEVICE_LOCAL_BIT)!;

    texture.sampler = vk::samplerCreateInfo()
    .setMagFilter(vk::FILTER_LINEAR)
    .setMinFilter(vk::FILTER_LINEAR)
    .setAddressModeU(vk::SAMPLER_ADDRESS_MODE_REPEAT)
    .setAddressModeV(vk::SAMPLER_ADDRESS_MODE_REPEAT)
    .setAddressModeW(vk::SAMPLER_ADDRESS_MODE_REPEAT)
    .setMipLodBias(0.0)
    .setMinLod(0.0)
    .setMaxLod(1.0)
    .setMipmapMode(vk::SAMPLER_MIPMAP_MODE_LINEAR)
    .setMaxAnisotropy(1.0)
    .setAnisotropyEnable(vk::FALSE)
    .setBorderColor(vk::BORDER_COLOR_FLOAT_OPAQUE_WHITE)
    .build(device)!;

    texture.imageView = vk::imageViewCreateInfo()
    .setViewType(vk::IMAGE_VIEW_TYPE_2D)
    .setFormat(format)
    .setComponents({
        .r = vk::COMPONENT_SWIZZLE_R,
        .g = vk::COMPONENT_SWIZZLE_G,
        .b = vk::COMPONENT_SWIZZLE_B,
        .a = vk::COMPONENT_SWIZZLE_A,
    })
    .setSubresourceRange({
        .aspectMask = vk::IMAGE_ASPECT_DEPTH_BIT,
        .baseMipLevel = 0,
        .baseArrayLayer = 0,
        .layerCount = 1,
        .levelCount = 1,
    })
    .setImage(depth_image)
    .build(device)!;

    device.@single_time_command(queue: queue; CommandBuffer command_buffer) {
        ImageMemoryBarrier imageMemoryBarrier = vk::imageMemoryBarrier()
        .setImage(depth_image)
        .setSubresourceRange({
            .aspectMask = vk::IMAGE_ASPECT_DEPTH_BIT,
            .baseMipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
            .levelCount = 1,
        })
        .setSrcAccessMask(0)
        .setDstAccessMask(vk::ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT)
        .setOldLayout(vk::IMAGE_LAYOUT_UNDEFINED)
        .setNewLayout(vk::IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL);

        vk::cmdPipelineBarrier(
            command_buffer,
            vk::PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | vk::PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
            vk::PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | vk::PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &imageMemoryBarrier
        );
    }!;

    self.push(texture);
    return depth_image;
}

fn DescriptorSetLayout? createDescriptorLayout(WriteDescriptorSet[] layouts, ShaderStageFlags[] flags, Device device) {
    DescriptorSetLayoutBinding* bindings = mem::new_array(DescriptorSetLayoutBinding, flags.len);
    defer mem::free(bindings);

    foreach (uint i, set: layouts) {
        DescriptorSetLayoutBinding binding = {
            .binding = i,
            .descriptorType = set.descriptorType,
            .descriptorCount = set.descriptorCount,
            .stageFlags = flags[i]
        };
        bindings[i] = binding;
    }

    DescriptorSetLayoutCreateInfo layoutCreateInfo = {
        .sType = vk::STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .flags = vk::DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR,
        .bindingCount = flags.len,
        .pBindings = bindings
    };

    return layoutCreateInfo.build(device)!;
}


fn PipelineLayer? createPipelineLayout(WriteDescriptorSet[] descriptor_layouts, ShaderStageFlags[] flags, PushConstantRange[] push_ranges, Device device) {
    List{DescriptorSetLayoutBinding} bindings;
    defer bindings.free();

    PipelineLayer layer;

    foreach (set: descriptor_layouts) layer.sets.push(set);
    foreach (uint i, set: descriptor_layouts) {
        DescriptorSetLayoutBinding binding = {
            .binding = i,
            .descriptorType = set.descriptorType,
            .descriptorCount = set.descriptorCount,
            .stageFlags = flags[i]
        };
        bindings.push(binding);
    }

    // Set-up descriptor info for uniform buffer usage
    DescriptorSetLayout descriptor_layout = vk::descriptorSetLayoutCreateInfo()
    .setFlags(vk::DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR)
    .setBindings(bindings.array_view()).build(device)!!;
    
    PipelineLayoutCreateInfo pipeline_layout_info = vk::pipelineLayoutCreateInfo()
    .setSetLayouts({ descriptor_layout });
    
    if (push_ranges.len > 0) pipeline_layout_info.setPushConstantRanges(push_ranges);

    layer.layout = pipeline_layout_info.build(device)!;
    layer.descriptor_layout = descriptor_layout;
    return layer;
}


fn void PipelineLayer.free(&self, Device device) {
    self.layout.free(device);
    self.descriptor_layout.free(device);
    self.sets.free();
}

fn vk::Image? DescriptorImages.add_cube_map(&self, String path, DeviceContext* context) {
    vk::Device device = context.device;
    vk::PhysicalDevice pdevice = context.pdevice;

     vk::Allocator* allocator = &context.allocator;

    stb::Image cube_map_image = stb::loadImage(path, stb::Channel.STBI_RGB_ALPHA)!;
    defer cube_map_image.free();
    
    // uint cube_map_height = cube_map_image.height / 6;
    vk::Format cube_format = vk::FORMAT_R8G8B8A8_UNORM;

    DescriptorImageInfo cube_texture = {
        .imageLayout = vk::IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    };

    const uint LAYER_COUNT = 6;

    uint cube_map_width = cube_map_image.width / LAYER_COUNT;

    vk::Image cube_image = vk::imageCreateInfo()
        .setImageType(vk::IMAGE_TYPE_2D)
        .setExtent({.width = cube_map_width, .height = cube_map_width, .depth = 1 })
        .setMipLevels(1)
        .setFlags(vk::IMAGE_CREATE_CUBE_COMPATIBLE_BIT)
        .setArrayLayers(LAYER_COUNT)
        .setSamples(vk::SAMPLE_COUNT_1_BIT)
        .setUsage(vk::IMAGE_USAGE_TRANSFER_DST_BIT | vk::IMAGE_USAGE_SAMPLED_BIT)
        .setInitialLayout(vk::IMAGE_LAYOUT_UNDEFINED)
        .setTiling(vk::IMAGE_TILING_OPTIMAL)
        .setFormat(cube_format)
        .build(device)!;

    vk::create_image_buffer(cube_image, allocator, properties: vk::MEMORY_PROPERTY_DEVICE_LOCAL_BIT)!;

    cube_texture.sampler = vk::samplerCreateInfo()
        .setMagFilter(vk::FILTER_LINEAR)
        .setMinFilter(vk::FILTER_LINEAR)
        .setAddressModeU(vk::SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
        .setAddressModeV(vk::SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
        .setAddressModeW(vk::SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
        .setMipLodBias(0.0)
        .setCompareOp(vk::COMPARE_OP_NEVER)
        .setMinLod(0.0)
        .setMaxLod(1.0)
        .setMaxAnisotropy(1.0)
        .setAnisotropyEnable(vk::FALSE)
        .setBorderColor(vk::BORDER_COLOR_FLOAT_OPAQUE_WHITE)
        .build(device)!;

    cube_texture.imageView = vk::imageViewCreateInfo()
        .setViewType(vk::IMAGE_VIEW_TYPE_CUBE)
        .setFormat(cube_format)
        .setSubresourceRange({
            .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = LAYER_COUNT,
            .levelCount = 1,
        }
    )
    .setImage(cube_image)
    .build(device)!;

	Memory stage_buffer = vk::new_buffer(
		allocator: allocator,
        usage: vk::BUFFER_USAGE_TRANSFER_SRC_BIT,
        properties: vk::MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk::MEMORY_PROPERTY_HOST_CACHED_BIT,
        data: cube_map_image.pixels,
        data_size: (usz)cube_map_image.width * cube_map_image.height * 4
    )!!;

    defer stage_buffer.free();

    context.device.@single_time_command(queue: context. graphics_queue; CommandBuffer command_buffer) {
        BufferImageCopy2[LAYER_COUNT] bufferCopyRegions;
        ImageMemoryBarrier2[LAYER_COUNT] transfer_barriers;
        ImageMemoryBarrier2[LAYER_COUNT] finalize_barriers;

        CopyBufferToImageInfo2 bufferCopyData = {
            .sType = vk::STRUCTURE_TYPE_COPY_BUFFER_TO_IMAGE_INFO_2,
            .dstImage = cube_image,
            .srcBuffer = stage_buffer.buffer,
            .dstImageLayout = vk::IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .regionCount = bufferCopyRegions.len,
            .pRegions = &bufferCopyRegions
        };

        for (uint i; i < bufferCopyRegions.len; i++) {
            transfer_barriers[i] = {
                .sType = vk::STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
                .srcStageMask = vk::PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                .dstStageMask = vk::PIPELINE_STAGE_TRANSFER_BIT,
                .srcAccessMask = 0,
                .dstAccessMask = vk::ACCESS_2_TRANSFER_WRITE_BIT,
                .image = cube_image,
                .oldLayout = vk::IMAGE_LAYOUT_UNDEFINED,
                .newLayout = vk::IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .subresourceRange = {
                    .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = i,
                    .layerCount = 1,
            }};

            finalize_barriers[i] = {
                .sType = vk::STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
                .srcStageMask = vk::PIPELINE_STAGE_TRANSFER_BIT,
                .dstStageMask = vk::PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                .srcAccessMask = vk::ACCESS_2_TRANSFER_WRITE_BIT,
                .dstAccessMask = vk::ACCESS_2_SHADER_READ_BIT,
                .image = cube_image,
                .oldLayout = vk::IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .newLayout = vk::IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                .subresourceRange = {
                    .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = i,
                    .layerCount = 1,
                } 
            };

            bufferCopyRegions[i] = {
                .sType = vk::STRUCTURE_TYPE_BUFFER_IMAGE_COPY_2,
                .bufferOffset = (long)cube_map_width * 4 * i,
                .bufferRowLength = 0,
                .bufferImageHeight = 0,
                .imageSubresource = {
                    .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
                    .mipLevel = 0,
                    .baseArrayLayer = i,
                    .layerCount = 1,
                },
                .imageOffset = { 0, 0, 0},
                .imageExtent = { .width = cube_map_image.width, .height = cube_map_image.height, .depth = 1 }
            };
        }

        vk::cmdPipelineBarrier2(command_buffer, &&vk::dependencyInfo()
        .setImageMemoryBarriers(&transfer_barriers));

        vk::cmdCopyBufferToImage2(
            command_buffer,
            &bufferCopyData
        );

        vk::cmdPipelineBarrier2(command_buffer, &&vk::dependencyInfo()
        .setImageMemoryBarriers(&finalize_barriers));
    }!;

    self.push(cube_texture);
    return cube_image;
}