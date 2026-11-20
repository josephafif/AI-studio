cmake_minimum_required(VERSION 3.18)
project(lmengine C)
# Motorn delas med verktygen på datorn: mobil/engine/lmengine.c
add_library(lmengine SHARED ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../engine/lmengine.c)
target_compile_options(lmengine PRIVATE -O3 -fopenmp -ffp-contract=fast)
if(ANDROID_ABI STREQUAL "arm64-v8a")
  # Snapdragon 8 Elite m.fl.: halvprecision och dot-product-instruktioner
  target_compile_options(lmengine PRIVATE -march=armv8.2-a+fp16+dotprod)
endif()
target_link_options(lmengine PRIVATE -fopenmp -static-openmp)
target_link_libraries(lmengine m)
