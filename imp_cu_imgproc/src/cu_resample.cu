// Copyright (c) 2015-2016, ETH Zurich, Wyss Zurich, Zurich Eye
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the ETH Zurich, Wyss Zurich, Zurich Eye nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL ETH Zurich, Wyss Zurich, Zurich Eye BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#include <imp/cu_imgproc/cu_resample.cuh>

#include <memory>
#include <cstdint>
#include <cmath>

#include <cuda_runtime.h>

#include <imp/core/types.hpp>
#include <imp/core/roi.hpp>
#include <imp/cu_core/cu_image_gpu.cuh>
#include <imp/cu_core/cu_utils.hpp>
#include <imp/cu_core/cu_texture.cuh>
#include <imp/cu_imgproc/cu_image_filter.cuh>

namespace ze {
namespace cu {

//-----------------------------------------------------------------------------
template<typename Pixel>
__global__ void k_resample(Pixel* d_dst, size_t stride,
                           uint32_t dst_width, uint32_t dst_height,
                           uint32_t roi_x, uint32_t roi_y,
                           float sf_x, float sf_y, Texture2D src_tex)
{
  const int x = blockIdx.x*blockDim.x + threadIdx.x + roi_x;
  const int y = blockIdx.y*blockDim.y + threadIdx.y + roi_y;
  if (x<dst_width && y<dst_height)
  {
    Pixel val;
    tex2DFetch(val, src_tex, x, y, sf_x, sf_y);
    d_dst[y*stride+x] = val;
  }
}

//-----------------------------------------------------------------------------
template<typename Pixel>
void resample(ImageGpu<Pixel>& dst,
              const ImageGpu<Pixel>& src,
              ze::InterpolationMode interp, bool gauss_prefilter)
{
  ze::Roi2u src_roi = src.roi();
  ze::Roi2u dst_roi = dst.roi();

  // scale factor for x/y > 0 && < 1 (for multiplication with dst coords in the kernel!)
  float sf_x = static_cast<float>(src_roi.width()) / static_cast<float>(dst_roi.width());
  float sf_y = static_cast<float>(src_roi.height()) / static_cast<float>(dst_roi.height());

  cudaTextureFilterMode tex_filter_mode =
      (interp == InterpolationMode::Linear) ? cudaFilterModeLinear
                                            : cudaFilterModePoint;
  if (src.bitDepth() < 32)
    tex_filter_mode = cudaFilterModePoint;

  std::shared_ptr<Texture2D> src_tex;
  std::unique_ptr<ImageGpu<Pixel>> filtered;
  if (gauss_prefilter)
  {
    float sf = .5f*(sf_x+sf_y);

    filtered.reset(new ImageGpu<Pixel>(src.size()));
    float sigma = 1/(3*sf) ;  // empirical magic
    std::uint16_t kernel_size = std::ceil(6.0f*sigma);
    if (kernel_size % 2 == 0)
      kernel_size++;

    ze::cu::filterGauss(*filtered, src, sigma, kernel_size);
    src_tex = filtered->genTexture(false, tex_filter_mode);
  }
  else
  {
    src_tex = src.genTexture(false, tex_filter_mode);
  }

  Fragmentation<> dst_frag(dst_roi.size());

  switch(interp)
  {
  case InterpolationMode::Point:
  case InterpolationMode::Linear:
    // fallthrough intended
    k_resample
        <<<
          dst_frag.dimGrid, dst_frag.dimBlock/*, 0, stream*/
        >>> (dst.data(), dst.stride(), dst.width(), dst.height(),
             dst_roi.x(), dst_roi.y(), sf_x , sf_y, *src_tex);
    break;
    //  case InterpolationMode::Cubic:
    //    cuTransformCubicKernel_32f_C1
    //        <<< dimGridOut, dimBlock, 0, stream >>> (dst.data(), dst.stride(), dst.width(), dst.height(),
    //                                      sf_x , sf_y);
    //    break;
    //  case InterpolationMode::CubicSpline:
    //    cuTransformCubicSplineKernel_32f_C1
    //        <<< dimGridOut, dimBlock, 0, stream >>> (dst.data(), dst.stride(), dst.width(), dst.height(),
    //                                      sf_x , sf_y);
    //    break;
  default:
    CHECK(false) << "unsupported interpolation type";
  }

  IMP_CUDA_CHECK();
}

//==============================================================================
//
// template instantiations for all our image types
//

template void resample(ImageGpu8uC1& dst, const ImageGpu8uC1& src, InterpolationMode interp, bool gauss_prefilter);
template void resample(ImageGpu8uC2& dst, const ImageGpu8uC2& src, InterpolationMode interp, bool gauss_prefilter);
template void resample(ImageGpu8uC4& dst, const ImageGpu8uC4& src, InterpolationMode interp, bool gauss_prefilter);

template void resample(ImageGpu16uC1& dst, const ImageGpu16uC1& src, InterpolationMode interp, bool gauss_prefilter);
template void resample(ImageGpu16uC2& dst, const ImageGpu16uC2& src, InterpolationMode interp, bool gauss_prefilter);
template void resample(ImageGpu16uC4& dst, const ImageGpu16uC4& src, InterpolationMode interp, bool gauss_prefilter);

template void resample(ImageGpu32sC1& dst, const ImageGpu32sC1& src, InterpolationMode interp, bool gauss_prefilter);
template void resample(ImageGpu32sC2& dst, const ImageGpu32sC2& src, InterpolationMode interp, bool gauss_prefilter);
template void resample(ImageGpu32sC4& dst, const ImageGpu32sC4& src, InterpolationMode interp, bool gauss_prefilter);

template void resample(ImageGpu32fC1& dst, const ImageGpu32fC1& src, InterpolationMode interp, bool gauss_prefilter);
template void resample(ImageGpu32fC2& dst, const ImageGpu32fC2& src, InterpolationMode interp, bool gauss_prefilter);
template void resample(ImageGpu32fC4& dst, const ImageGpu32fC4& src, InterpolationMode interp, bool gauss_prefilter);


} // namespace cu
} // namespace ze
