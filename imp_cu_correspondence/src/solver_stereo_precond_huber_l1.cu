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
#include <imp/cu_correspondence/solver_stereo_precond_huber_l1.cuh>

#include <cuda_runtime.h>
#include <glog/logging.h>

#include <imp/cu_correspondence/variational_stereo_parameters.hpp>
#include <imp/cu_core/cu_image_gpu.cuh>
#include <imp/cu_imgproc/cu_image_filter.cuh>
#include <imp/cu_imgproc/cu_resample.cuh>
#include <imp/cu_core/cu_utils.hpp>
#include <imp/cu_core/cu_texture.cuh>
#include <imp/cu_core/cu_math.cuh>

#include "warped_gradients_kernel.cuh"
#include "solver_precond_huber_l1_kernel.cuh"

namespace ze {
namespace cu {

//------------------------------------------------------------------------------
SolverStereoPrecondHuberL1::~SolverStereoPrecondHuberL1()
{
  // thanks to smart pointers
}

//------------------------------------------------------------------------------
SolverStereoPrecondHuberL1::SolverStereoPrecondHuberL1(
    const Parameters::Ptr& params,
    ze::Size2u size,
    size_t level)
  : SolverStereoAbstract(params, size, level)
{
  u_.reset(new ImageGpu32fC1(size));
  u_prev_.reset(new ImageGpu32fC1(size));
  u0_.reset(new ImageGpu32fC1(size));
  pu_.reset(new ImageGpu32fC2(size));
  q_.reset(new ImageGpu32fC1(size));
  ix_.reset(new ImageGpu32fC1(size));
  it_.reset(new ImageGpu32fC1(size));
  xi_.reset(new ImageGpu32fC1(size));

  // and its textures
  u_tex_ = u_->genTexture(false, cudaFilterModeLinear);
  u_prev_tex_ =  u_prev_->genTexture(false, cudaFilterModeLinear);
  u0_tex_ =  u0_->genTexture(false, cudaFilterModeLinear);
  pu_tex_ =  pu_->genTexture(false, cudaFilterModeLinear);
  q_tex_ =  q_->genTexture(false, cudaFilterModeLinear);
  ix_tex_ =  ix_->genTexture(false, cudaFilterModeLinear);
  it_tex_ =  it_->genTexture(false, cudaFilterModeLinear);
  xi_tex_ =  xi_->genTexture(false, cudaFilterModeLinear);
}

//------------------------------------------------------------------------------
void SolverStereoPrecondHuberL1::init()
{
  u_->setValue(0.0f);
  pu_->setValue(0.0f);
  q_->setValue(0.0f);
  // other variables are init and/or set when needed!
}

//------------------------------------------------------------------------------
void SolverStereoPrecondHuberL1::init(const SolverStereoAbstract& rhs)
{
  const SolverStereoPrecondHuberL1* from =
      dynamic_cast<const SolverStereoPrecondHuberL1*>(&rhs);

  float inv_sf = 1./params_->ctf.scale_factor; // >1 for adapting prolongated disparities

  if(params_->ctf.apply_median_filter)
  {
    ze::cu::filterMedian3x3(*from->u0_, *from->u_);
    ze::cu::resample(*u_, *from->u0_, ze::InterpolationMode::Point, false);
  }
  else
  {
    ze::cu::resample(*u_, *from->u_, ze::InterpolationMode::Point, false);
  }
  *u_ *= inv_sf;

  ze::cu::resample(*pu_, *from->pu_, ze::InterpolationMode::Point, false);
  ze::cu::resample(*q_, *from->q_, ze::InterpolationMode::Point, false);
}

//------------------------------------------------------------------------------
void SolverStereoPrecondHuberL1::solve(std::vector<ImageGpu32fC1::Ptr> images)
{
  VLOG(100) << "StereoCtFWarpingLevelPrecondHuberL1: solving level "
            << level_ << " with " << images.size() << " images";

  // sanity check:
  // TODO

  // image textures
  i1_tex_ = images.at(0)->genTexture(false, cudaFilterModeLinear);
  i2_tex_ = images.at(1)->genTexture(false, cudaFilterModeLinear);
  u_->copyTo(*u_prev_);
  Fragmentation<> frag(size_);

  // constants
  constexpr float tau = 0.95f;
  constexpr float sigma = 0.95f;
  float lin_step = 0.5f;

  // precond
  constexpr float eta = 2.0f;

  // warping
  for (uint32_t warp = 0; warp < params_->ctf.warps; ++warp)
  {
    VLOG(101) << "SOLVING warp iteration of Huber-L1 stereo model. warp: " << warp;

    u_->copyTo(*u0_);

    // compute warped spatial and temporal gradients
    k_warpedGradients
        <<<
          frag.dimGrid, frag.dimBlock
        >>> (ix_->data(), it_->data(), ix_->stride(), ix_->width(), ix_->height(),
             *i1_tex_, *i2_tex_, *u0_tex_);

    // compute preconditioner
    k_preconditioner
        <<<
          frag.dimGrid, frag.dimBlock
        >>> (xi_->data(), xi_->stride(), xi_->width(), xi_->height(),
             params_->lambda, *ix_tex_);


    for (uint32_t iter = 0; iter < params_->ctf.iters; ++iter)
    {
      // dual update kernel
      k_dualUpdate
          <<<
            frag.dimGrid, frag.dimBlock
          >>> (pu_->data(), pu_->stride(), q_->data(), q_->stride(),
               size_.width(), size_.height(),
               params_->lambda, params_->eps_u, sigma, eta,
               *u_prev_tex_, *u0_tex_, *pu_tex_, *q_tex_, *ix_tex_, *it_tex_);

      // and primal update kernel
      k_primalUpdate
          <<<
            frag.dimGrid, frag.dimBlock
          >>> (u_->data(), u_prev_->data(), u_->stride(),
               size_.width(), size_.height(),
               params_->lambda, tau, lin_step,
               *u_tex_, *u0_tex_, *pu_tex_, *q_tex_, *ix_tex_, *xi_tex_);
    } // iters
    lin_step /= 1.2f;

  } // warps
  IMP_CUDA_CHECK();
}



} // namespace cu
} // namespace ze

