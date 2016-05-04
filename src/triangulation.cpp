#include <ze/geometry/triangulation.h>

#include <algorithm>
#include <ze/common/logging.hpp>
#include <ze/common/matrix.h>
#include <ze/geometry/pose_optimizer.h>

namespace ze {

//------------------------------------------------------------------------------
Position triangulateNonLinear(
    const Transformation& T_A_B,
    const Eigen::Ref<const Bearing>& f_A,
    const Eigen::Ref<const Bearing>& f_B)
{
  Bearing f_A_hat = T_A_B.getRotation().rotate(f_B);
  Vector2 b(
        T_A_B.getPosition().dot(f_A),
        T_A_B.getPosition().dot(f_A_hat));
  Matrix2 A;
  A(0,0) = f_A.dot(f_A);
  A(1,0) = f_A.dot(f_A_hat);
  A(0,1) = -A(1,0);
  A(1,1) = -f_A_hat.dot(f_A_hat);
  Vector2 lambda = A.inverse() * b;
  Position xm = lambda(0) * f_A;
  Position xn = T_A_B.getPosition() + lambda(1) * f_A_hat;
  Position p_A(0.5 * ( xm + xn ));
  return p_A;
}

//------------------------------------------------------------------------------
void triangulateManyAndComputeAngularErrors(
    const Transformation& T_A_B,
    const Bearings& f_A_vec,
    const Bearings& f_B_vec,
    Positions& p_A,
    VectorX& reprojection_erors)
{
  CHECK_EQ(f_A_vec.cols(), f_B_vec.cols());
  CHECK_EQ(f_A_vec.cols(), p_A.cols());
  CHECK_EQ(f_A_vec.cols(), reprojection_erors.size());
  const Transformation T_B_A = T_A_B.inverse();
  for (int i = 0; i < f_A_vec.cols(); ++i)
  {
    p_A.col(i) = triangulateNonLinear(T_A_B, f_A_vec.col(i), f_B_vec.col(i));
    Bearing f_A_predicted = p_A.col(i).normalized();
    Bearing f_B_predicted = (T_B_A * p_A.col(i)).normalized();

    // Bearing-vector based outlier criterium (select threshold accordingly):
    // 1 - (f1' * f2) = 1 - cos(alpha) as used in OpenGV.
    FloatType reproj_error_1 = 1.0 - (f_A_vec.col(i).dot(f_A_predicted));
    FloatType reproj_error_2 = 1.0 - (f_B_vec.col(i).dot(f_B_predicted));
    reprojection_erors(i) = reproj_error_1 + reproj_error_2;
  }
}

//------------------------------------------------------------------------------
std::pair<Vector4, bool> triangulateHomogeneousDLT(
    const TransformationVector& T_C_W,
    const Bearings& p_C,
    const FloatType rank_tol)
{
  // Number of observations.
  size_t m = T_C_W.size();
  CHECK_GE(m, 2u);

  // Compute unit-plane coorinates (divide by z) from bearing vectors.
  const Matrix2X uv = p_C.topRows<2>().array().rowwise() / p_C.bottomRows<1>().array();

  // Allocate DLT matrix.
  MatrixX4 A(m * 2, 4);
  A.setZero();

  // Fill DLT matrix.
  for (size_t i = 0; i < m; ++i)
  {
    //! @todo: Think if this can be optimized, e.g. without computing the Matrix44 and uv.
    size_t row = i * 2;
    Matrix44 projection = T_C_W[i].getTransformationMatrix();
    A.row(row)     = uv(0, i) * projection.row(2) - projection.row(0);
    A.row(row + 1) = uv(1, i) * projection.row(2) - projection.row(1);
  }
  int rank;
  FloatType error;
  VectorX v;
  std::tie(rank, error, v) = directLinearTransform(A, rank_tol);

  // Return homogeneous coordinates and success.
  Vector4 p_W_homogeneous = v;
  bool success = (rank < 3) ? false : true;
  return std::make_pair(p_W_homogeneous, success);
}

//------------------------------------------------------------------------------
void triangulateGaussNewton(
    const TransformationVector& T_C_W,
    const Bearings& p_C,
    Eigen::Ref<Position> p_W)
{
  Position p_W_old = p_W;
  FloatType chi2 = 0.0;
  Matrix3 A;
  Vector3 b;

  if(T_C_W.size() < 2u)
  {
    LOG(ERROR) << "Optimizing point with less than two observations";
    return;
  }

  constexpr FloatType eps{0.0000000001};
  for (uint32_t iter = 0; iter < 5u; ++iter)
  {
    A.setZero();
    b.setZero();
    FloatType new_chi2{0.0};

    // compute residuals
    for(size_t i = 0; i < T_C_W.size(); ++i)
    {
      const Position p_C_estimated = T_C_W[i] * p_W;
      Matrix23 J = dUv_dLandmark(p_C_estimated) * T_C_W[i].getRotationMatrix();
      Vector2 e(ze::project2(p_C_estimated) - ze::project2(p_C.col(i)));
      A.noalias() += J.transpose() * J;
      b.noalias() -= J.transpose() * e;
      new_chi2 += e.squaredNorm();
    }

    // solve linear system
    const Vector3 dp(A.ldlt().solve(b));

    // check if error increased
    if((iter > 0 && new_chi2 > chi2) || std::isnan(dp[0]))
    {
      VLOG(100) << "it " << iter
                << "\t FAILURE \t new_chi2 = " << new_chi2;

      p_W = p_W_old; // roll-back
      break;
    }

    // update the model
    Position new_point = traits<Position>::retract(p_W, dp);
    p_W_old = p_W;
    p_W = new_point;
    chi2 = new_chi2;

    VLOG(100) << "it " << iter
              << "\t Success \t new_chi2 = " << new_chi2;

    // stop when converged
    if(ze::normMax(dp) <= eps)
    {
      break;
    }
  }
}

} // namespace ze
