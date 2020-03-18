/* Copyright (c) 2020 PaddlePaddle Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */

#include <cublas.h>
#include "paddle/fluid/framework/eigen.h"
#include "paddle/fluid/operators/math/blas.h"
#include "paddle/fluid/operators/rank_attention.cu.h"
#include "paddle/fluid/operators/rank_attention_op.h"
#include "paddle/fluid/platform/cuda_primitives.h"
#include "paddle/fluid/platform/gpu_info.h"

namespace paddle {
namespace operators {

using framework::Tensor;

template <typename DeviceContext, typename T>
class RankAttentionCUDAKernel : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext &ctx) const override {
    auto *X = ctx.Input<Tensor>("X");
    auto *rank_offset = ctx.Input<Tensor>("RankOffset");
    auto *param = ctx.Input<Tensor>("RankParam");
    auto *input_help = ctx.Output<Tensor>("InputHelp");
    auto *ins_rank = ctx.Output<Tensor>("InsRank");
    int max_rank = ctx.Attr<int>("MaxRank");
    auto *Out = ctx.Output<Tensor>("Out");

    // check dims
    auto x_dims = X->dims();
    auto ins_num = x_dims[0];
    auto x_fea_dim = x_dims[1];
    auto para_dims = param->dims();
    auto para_row = para_dims[0];
    auto para_col = para_dims[1];
    auto rank_offset_dims = rank_offset->dims();
    PADDLE_ENFORCE_EQ(
        rank_offset_dims[0], ins_num,
        platform::errors::InvalidArgument("Input(RankOffset) has wrong rows."));
    PADDLE_ENFORCE_EQ((rank_offset_dims[1] - 1) / 2, max_rank,
                      platform::errors::InvalidArgument(
                          "Input(RankOffset) has wrong columns."));
    PADDLE_ENFORCE_EQ(
        max_rank * max_rank * x_fea_dim, para_row,
        platform::errors::InvalidArgument("Input(RankParam) has wrong rows."));

    int block_matrix_row = max_rank * x_fea_dim;

    auto &dev_ctx = ctx.template device_context<platform::CUDADeviceContext>();

    Tensor param_help;
    param_help = ctx.AllocateTmpTensor<T, DeviceContext>(
        {ins_num * block_matrix_row, para_col}, dev_ctx);
    param_help.mutable_data<T>(ctx.GetPlace());

    input_help->mutable_data<T>(ctx.GetPlace());
    ins_rank->mutable_data<T>(ctx.GetPlace());
    Out->mutable_data<T>(ctx.GetPlace());

    // initialize
    auto param_help_eigen = framework::EigenVector<T>::Flatten(param_help);
    auto input_help_eigen = framework::EigenVector<T>::Flatten(*input_help);
    auto ins_rank_eigen = framework::EigenVector<T>::Flatten(*ins_rank);
    auto out_eigen = framework::EigenVector<T>::Flatten(*Out);

    auto &place = *ctx.template device_context<platform::CUDADeviceContext>()
                       .eigen_device();

    param_help_eigen.device(place) =
        param_help_eigen.constant(static_cast<T>(0));
    input_help_eigen.device(place) =
        input_help_eigen.constant(static_cast<T>(0));
    ins_rank_eigen.device(place) = ins_rank_eigen.constant(static_cast<T>(-1));
    out_eigen.device(place) = out_eigen.constant(static_cast<T>(0));

    // get data ptr
    T *input_help_data = input_help->data<T>();
    T *param_help_data = param_help.data<T>();
    T *ins_rank_data = ins_rank->data<T>();
    T *out_data = Out->data<T>();

    expand_rank_attention_input(
        ctx.cuda_device_context().stream(), X->data<T>(), ins_num, x_fea_dim,
        input_help_data, ins_num, block_matrix_row, rank_offset->data<int>(),
        rank_offset_dims[0], rank_offset_dims[1], ins_rank_data, max_rank);

    expand_rank_attention_param(
        ctx.cuda_device_context().stream(), X->data<T>(), ins_num, x_fea_dim,
        rank_offset->data<int>(), rank_offset_dims[0], rank_offset_dims[1],
        param->data<T>(), para_row, para_col, param_help_data,
        ins_num * block_matrix_row, para_col, max_rank);

    CBLAS_TRANSPOSE transA = CblasNoTrans;
    CBLAS_TRANSPOSE transB = CblasNoTrans;

    T alpha = 1;
    T beta = 0;
    int64_t strideA = block_matrix_row;
    int64_t strideB = block_matrix_row * para_col;

    auto blas = math::GetBlas<platform::CUDADeviceContext, T>(dev_ctx);
    blas.BatchedGEMM(transA, transB, 1, para_col, block_matrix_row, alpha,
                     input_help_data, param_help_data, beta, out_data, ins_num,
                     strideA, strideB);
  }
};

template <typename DeviceContext, typename T>
class RankAttentionGradOpCUDAKernel : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext &ctx) const override {
    auto *X = ctx.Input<Tensor>("X");                     // not use data
    auto *rank_offset = ctx.Input<Tensor>("RankOffset");  // not use data
    auto *param = ctx.Input<Tensor>("RankParam");         // not use data
    auto *input_help = ctx.Input<Tensor>("InputHelp");
    // auto *param_help = ctx.Input<Tensor>("ParamHelp");
    auto *ins_rank = ctx.Input<Tensor>("InsRank");
    auto *dout = ctx.Input<Tensor>(framework::GradVarName("Out"));

    // auto *dX = ctx.Output<Tensor>(framework::GradVarName("X"));
    auto *drank_para = ctx.Output<Tensor>(framework::GradVarName("RankParam"));

    // get dim
    auto x_dims = X->dims();
    auto ins_num = x_dims[0];
    auto x_fea_dim = x_dims[1];
    auto para_dims = param->dims();
    auto para_row = para_dims[0];
    auto para_col = para_dims[1];
    auto rank_offset_dims = rank_offset->dims();
    auto max_rank = (rank_offset_dims[1] - 1) / 2;
    int block_matrix_row = max_rank * x_fea_dim;
    auto &dev_ctx = ctx.template device_context<platform::CUDADeviceContext>();
    auto &place = *ctx.template device_context<platform::CUDADeviceContext>()
                       .eigen_device();

    // initialize out grad
    drank_para->mutable_data<T>(ctx.GetPlace());
    // dX->mutable_data<T>(ctx.GetPlace());
    auto drank_para_eigen = framework::EigenVector<T>::Flatten(*drank_para);
    // auto dX_eigen = framework::EigenVector<T>::Flatten(*dX);
    drank_para_eigen.device(place) =
        drank_para_eigen.constant(static_cast<T>(0));
    // dX_eigen.device(place) = dX_eigen.constant(static_cast<T>(0));

    // copy data
    Tensor param_grad;
    // Tensor input_grad;
    param_grad = ctx.AllocateTmpTensor<T, DeviceContext>(
        {ins_num * block_matrix_row, para_col}, dev_ctx);
    // input_grad = ctx.AllocateTmpTensor<T, DeviceContext>(
    //    {ins_num, block_matrix_row}, dev_ctx);

    param_grad.mutable_data<T>(ctx.GetPlace());
    // input_grad.mutable_data<T>(ctx.GetPlace());

    // initialize
    auto param_grad_eigen = framework::EigenVector<T>::Flatten(param_grad);
    // auto input_grad_eigen = framework::EigenVector<T>::Flatten(input_grad);

    param_grad_eigen.device(place) =
        param_grad_eigen.constant(static_cast<T>(0));
    // input_grad_eigen.device(place) =
    //    input_grad_eigen.constant(static_cast<T>(0));

    // get data ptr
    const T *input_help_data = input_help->data<T>();
    // const T *param_help_data = param_help->data<T>();
    const T *ins_rank_data = ins_rank->data<T>();
    // T *input_grad_data = input_grad.data<T>();
    T *param_grad_data = param_grad.data<T>();

    auto blas = math::GetBlas<platform::CUDADeviceContext, T>(dev_ctx);
    T alpha = 1;
    T beta = 0;

    // get param_grad
    CBLAS_TRANSPOSE transA = CblasTrans;
    CBLAS_TRANSPOSE transB = CblasNoTrans;
    int64_t strideA = block_matrix_row;
    int64_t strideB = para_col;

    blas.BatchedGEMM(transA, transB, block_matrix_row, para_col, 1, alpha,
                     input_help_data, dout->data<T>(), beta, param_grad_data,
                     ins_num, strideA, strideB);

    // merge param_grad to get drank_para
    merge_rank_attention_param_grad(
        ctx.cuda_device_context().stream(), param_grad_data,
        ins_num * block_matrix_row, para_col, drank_para->data<T>(), para_row,
        para_col, ins_rank_data, ins_num, max_rank, x_fea_dim);

    // get input_grad
    // CBLAS_TRANSPOSE transC = CblasNoTrans;
    // CBLAS_TRANSPOSE transD = CblasTrans;
    // int64_t strideC = para_col;
    // int64_t strideD = block_matrix_row * para_col;

    // blas.BatchedGEMM(transC, transD, 1, block_matrix_row, para_col, alpha,
    //                 dout->data<T>(), param_help_data, beta, input_grad_data,
    //                 ins_num, strideC, strideD);

    //// merge input_grad to get dX
    // merge_rank_attention_input_grad(
    //    ctx.cuda_device_context().stream(), input_grad_data, ins_num,
    //    block_matrix_row, dX->data<T>(), ins_num, x_fea_dim,
    //    rank_offset->data<int>(), rank_offset_dims[0], rank_offset_dims[1],
    //    ins_rank_data, x_fea_dim);
  }
};

}  // namespace operators
}  // namespace paddle

namespace ops = paddle::operators;
using GPUCtx = paddle::platform::CUDADeviceContext;
REGISTER_OP_CUDA_KERNEL(rank_attention,
                        ops::RankAttentionCUDAKernel<GPUCtx, float>,
                        ops::RankAttentionCUDAKernel<GPUCtx, double>);

REGISTER_OP_CUDA_KERNEL(rank_attention_grad,
                        ops::RankAttentionGradOpCUDAKernel<GPUCtx, float>,
                        ops::RankAttentionGradOpCUDAKernel<GPUCtx, double>);
