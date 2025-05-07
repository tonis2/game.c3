# Game

Making a 3D game with Vulkan and C3 language, currently very basic


### Example
Running example:
Install [C3](https://c3-lang.org/), [VulkanSDK](https://vulkan.lunarg.com/sdk/home)
Then run example with `c3c run game`

------
### Running with vulkan on macOS

Install [VulkanSDK](https://vulkan.lunarg.com/sdk/home#mac) and add vulkan lib file path as `rpath` to the run command.
Its the folder with `vulkan.1.dylib` file
````
c3c run game -z -rpath -z /Users/my_user/VulkanSDK/macOS/lib
````

------
### Running vulkan on linux
Install [VulkanSDK](https://vulkan.lunarg.com/sdk/home#mac)

Choosing wayland or X11 can be done with feature tag inside C3 `project.json`
```
"features": ["WAYLAND"]
"features": ["X11"]

```
