#= src/spfft1.jl
=#

abstract type SpFFTPlan1{T,K} end

const NB = 128  # default block size; actual used can be set on FFT execution

function spfft_blkdiv(n::Integer, k::Integer)
  l = k
  while n % l > 0
    l -= 1
  end
  m = div(n, l)
  l, m
end

function spfft_chkidx(n::Integer, idx::AbstractVector{T}) where {T<:Integer}
  n > 0 || throw(ArgumentError("n"))
  for i in idx
    (1 <= i <= n) || throw(DomainError())
  end
end

spfft_size(P::SpFFTPlan1) = (size(P.X)..., length(P.w))

# complex transforms
# - underlying FFT is c2c but can also take real input/output
# -- if real  input, will convert from real to complex
# -- if real output, will take real part
# - note: (r2c, f2s) and (c2r, s2f) can be further optimized

struct cSpFFTPlan1{T<:SpFFTComplex,K} <: SpFFTPlan1{T,K}
  X::Matrix{T}
  F::FFTPlan{T,K}
  w::Vector{T}
  col::Vector{Int}
  p::Vector{Int}
end

spfft_rc(::Type{T}, x) where {T<:Real   } = real(x)  # no inexact error check
spfft_rc(::Type{T}, x) where {T<:Complex} =      x

for (f, K) in ((:fft, FORWARD), (:bfft, BACKWARD))
  sf  = Symbol("sp", f)
  psf = Symbol("plan_", sf)
  pf  = Symbol("plan_", f, "!")
  f2s = Symbol(sf, "_f2s!")
  s2f = Symbol(sf, "_s2f!")
  @eval begin
    function $psf(::Type{T}, n::Integer, idx::AbstractVector{Ti};
                  args...) where {T<:SpFFTComplex,Ti<:Integer}
      spfft_chkidx(n, idx)
      k = length(idx)
      l, m = spfft_blkdiv(n, k)
      X = Array{T}(undef, l, m)
      F = $pf(X, 1; args...)
      wm = exp(2im*$K*pi/m)
      wn = exp(2im*$K*pi/n)
      w   = Array{T  }(undef, k)
      col = Array{Int}(undef, k)
      @inbounds for i = 1:k
        rowm1, colm1 = divrem(idx[i]-1, l)
        w[i] = wm^rowm1 * wn^colm1
        col[i] = colm1 + 1
      end
      p = sortperm(col)
      permute!(  w, p)
      permute!(col, p)
      cSpFFTPlan1{T,$K}(X, F, w, col, p)
    end

    function $f2s(y::AbstractVector{Ty}, P::cSpFFTPlan1{T,K},
                  x::AbstractVector{Tx}; nb::Integer=$NB) where {T,K,Tx,Ty}
      l, m, k = spfft_size(P)
      length(x) == l*m || throw(DimensionMismatch)
      length(y) == k   || throw(DimensionMismatch)
      transpose!(P.X, reshape(x,(m,l)))
      P.F*P.X
      nb = min(nb, k)
      t = Array{Ty}(undef, nb)
      s = Array{T }(undef, nb)
      idx = 0
      while idx < k
        fill!(t, 0)
        fill!(s, 1)
        nbi = min(nb, k-idx)
        @inbounds for j = 1:m
          for i = 1:nbi
            ii = idx + i
            t[i] += spfft_rc(Ty, s[i]*P.X[P.col[ii],j])
            s[i] *= P.w[ii]
          end
        end
        @inbounds for i = 1:nbi
          y[P.p[idx+i]] = t[i]
        end
        idx += nbi
      end
      y
    end

    function $s2f(y::AbstractVector{Ty}, P::cSpFFTPlan1{T,K},
                  x::AbstractVector{Tx}; nb::Integer=$NB) where {T,K,Tx,Ty}
      l, m, k = spfft_size(P)
      length(x) == k   || throw(DimensionMismatch)
      length(y) == l*m || throw(DimensionMismatch)
      fill!(P.X, 0)
      nb = min(nb, k)
      t = Array{Tx}(undef, nb)
      s = Array{T }(undef, nb)
      idx = 0
      while idx < k
        fill!(s, 1)
        nbi = min(nb, k-idx)
        @inbounds for i = 1:nbi
          t[i] = x[P.p[idx+i]]
        end
        @inbounds for j = 1:m
          for i = 1:nbi
            ii = idx + i
            P.X[P.col[ii],j] += s[i]*t[i]
            s[i] *= P.w[ii]
          end
        end
        idx += nbi
      end
      P.F*P.X
      transpose_f!(z->spfft_rc(Ty,z), reshape(y,(m,l)), P.X)
    end
  end
end

# real transforms

## (r2c, f2s)

struct rSpFFTPlan1{T<:SpFFTReal} <: SpFFTPlan1{T,FORWARD}
  X::Matrix{T}
  Xc::Matrix{Complex{T}}
  F::FFTPlan{T,FORWARD}
  w::Vector{Complex{T}}
  col::Vector{Int}
  p::Vector{Int}
end

function sprfft_fullcomplex(X::Matrix{T}, i::Integer, j::Integer, n::Integer,
                            inyq::Integer) where {T<:SpFFTComplex}
  if i <= inyq  return      X[  i  ,j]
  else          return conj(X[n-i+2,j])  # hermitian conjugate
  end
end

function plan_sprfft(::Type{T}, n::Integer, idx::AbstractVector{Ti};
                     args...) where {T<:SpFFTReal,Ti<:Integer}
  spfft_chkidx(n, idx)
  k = length(idx)
  l, m = spfft_blkdiv(n, k)
  lc = div(l, 2) + 1
  Tc = Complex{T}
  X  = Array{T }(undef, l , m)
  Xc = Array{Tc}(undef, lc, m)
  F = plan_rfft(X, 1; args...)
  wm = exp(-2im*pi/m)
  wn = exp(-2im*pi/n)
  w   = Array{Tc }(undef, k)
  col = Array{Int}(undef, k)
  @inbounds for i = 1:k
    rowm1, colm1 = divrem(idx[i]-1, l)
    w[i] = wm^rowm1 * wn^colm1
    col[i] = colm1 + 1
  end
  p = sortperm(col)
  permute!(  w, p)
  permute!(col, p)
  rSpFFTPlan1{T}(X, Xc, F, w, col, p)
end

function sprfft_f2s!(
    y::AbstractVector{Ty}, P::rSpFFTPlan1{T}, x::AbstractVector{Tx};
    nb::Integer=NB) where {T,Tx<:Real,Ty<:Complex}
  l, m, k = spfft_size(P)
  length(x) == l*m || throw(DimensionMismatch)
  length(y) == k   || throw(DimensionMismatch)
  transpose!(P.X, reshape(x,(m,l)))
  mul!(P.Xc, P.F, P.X)
  nb = min(nb, k)
  Tc = Complex{T}
  t = Array{Ty}(undef, nb)
  s = Array{Tc}(undef, nb)
  nyq = size(P.Xc, 1)
  idx = 0
  while idx < k
    fill!(t, 0)
    fill!(s, 1)
    nbi = min(nb, k-idx)
    @inbounds for j = 1:m
      for i = 1:nbi
        ii = idx + i
        z = sprfft_fullcomplex(P.Xc, P.col[ii], j, l, nyq)
        t[i] += s[i]*z
        s[i] *= P.w[ii]
      end
    end
    @inbounds for i = 1:nbi
      y[P.p[idx+i]] = t[i]
    end
    idx += nbi
  end
  y
end

## (c2r, s2f)
## - input must contain only nonredundant frequencies, i.e., up to index n/2 + 1
##   for a full signal of size n

struct brSpFFTPlan1{T<:SpFFTReal,Tc<:SpFFTComplex} <: SpFFTPlan1{T,BACKWARD}
  X::Matrix{T}
  Xc::Matrix{Tc}
  F::FFTPlan{Tc,BACKWARD}
  k::Int
  w::Vector{Tc}
  col::Vector{Int}
  p::Vector{Int}
end

spbrfft_size(P::brSpFFTPlan1) = (spfft_size(P)..., P.k)

function plan_spbrfft(::Type{T}, n::Integer, idx::AbstractVector{Ti};
                      args...) where {T<:SpFFTReal,Ti<:Integer}
  nyqm1 = div(n, 2)
  spfft_chkidx(nyqm1+1, idx)
  k = length(idx)
  l, m = spfft_blkdiv(n, k)
  lc = div(l, 2) + 1
  Tc = Complex{T}
  X  = Array{T }(undef, l , m)
  Xc = Array{Tc}(undef, lc, m)
  F = plan_brfft(Xc, l, 1; args...)
  wm = exp(2im*pi/m)
  wn = exp(2im*pi/n)
  w   = Array{Tc }(undef, 0)
  col = Array{Int}(undef, 0)
  xp  = Array{Int}(undef, 0)
  sizehint!(  w, k)
  sizehint!(col, k)
  sizehint!( xp, k)
  @inbounds for i = 1:k
    idxm1 = idx[i] - 1
    rowm1, colm1 = divrem(idxm1, l)
    if colm1 < lc
      push!(w, wm^rowm1 * wn^colm1)
      push!(col, colm1 + 1)
      push!(xp, i)
    end
    (idxm1 == 0 || (n % 2 == 0 && idxm1 == nyqm1)) && continue
    idxm1 = n - idxm1
    rowm1, colm1 = divrem(idxm1, l)
    if colm1 < lc
      push!(w, wm^rowm1 * wn^colm1)
      push!(col, colm1 + 1)
      push!(xp, -i)
    end
  end
  p = sortperm(col)
  permute!(  w, p)
  permute!(col, p)
  permute!( xp, p)
  brSpFFTPlan1{T,Tc}(X, Xc, F, k, w, col, xp)
end

function spbrfft_s2f!(
    y::AbstractVector{Ty}, P::brSpFFTPlan1{T}, x::AbstractVector{Tx};
    nb::Integer=NB) where {T,Tx<:Complex,Ty<:Real}
  l, m, kc, k = spbrfft_size(P)
  length(x) == k   || throw(DimensionMismatch)
  length(y) == l*m || throw(DimensionMismatch)
  fill!(P.Xc, 0)
  nb = min(nb, kc)
  Tc = Complex{T}
  t = Array{Tx}(undef, nb)
  s = Array{Tc}(undef, nb)
  idx = 0
  while idx < kc
    fill!(s, 1)
    nbi = min(nb, kc-idx)
    @inbounds for i = 1:nbi
      p = P.p[idx+i]
      t[i] = p > 0 ? x[p] : conj(x[-p])
    end
    @inbounds for j = 1:m
      for i = 1:nbi
        ii = idx + i
        P.Xc[P.col[ii],j] += s[i]*t[i]
        s[i] *= P.w[ii]
      end
    end
    idx += nbi
  end
  mul!(P.X, P.F, P.Xc)
  transpose!(reshape(y,(m,l)), P.X)
  y
end
