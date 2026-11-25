cmake_minimum_required(VERSION 3.20)
project(uidrive OBJCXX)

set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

add_library(uidrive SHARED server.mm ax.mm touch.mm)
target_compile_options(uidrive PRIVATE -fobjc-arc -fvisibility=hidden)
target_link_libraries(uidrive PRIVATE "-framework UIKit" "-framework Foundation" "-framework CoreGraphics")
