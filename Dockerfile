# syntax=docker/dockerfile:1

# arbor - Tree Segmentation in MLS/TLS Point Clouds
#
# Base image: rocker/geospatial ships R plus the geospatial system stack
# (GDAL, GEOS, PROJ) and the `sf` / `terra` packages that arbor imports.
# Pin the tag to a specific R version for reproducible builds.
FROM docker.io/rocker/geospatial:4.5.1

# ---------------------------------------------------------------------------
# System dependencies not already in the base image
#   - libeigen3-dev : arbor's C++ sources include <Eigen/...> (see src/Makevars)
#   - mesa / X11    : build-time requirements for the `rgl` package
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      libeigen3-dev \
      libgl1-mesa-dev \
      libglu1-mesa-dev \
      libx11-dev \
      libfreetype6-dev \
      libglpk-dev \
    && rm -rf /var/lib/apt/lists/*

# rgl must run without an X server / GPU inside the container.
ENV RGL_USE_NULL=TRUE

# Pull r-lidar packages (lidR and friends) from r-universe, then CRAN.
ENV R_REPOS="https://r-lidar.r-universe.dev https://packagemanager.posit.co/cran/__linux__/noble/latest https://cloud.r-project.org"

WORKDIR /pkg

# ---------------------------------------------------------------------------
# Install R package dependencies first so this layer is cached across
# source-only changes. Only the DESCRIPTION is needed to resolve them.
# ---------------------------------------------------------------------------
COPY DESCRIPTION .
RUN Rscript -e 'options(repos = strsplit(Sys.getenv("R_REPOS"), " ")[[1]])' \
            -e 'install.packages("pak")' \
            -e 'pak::local_install_deps(".", dependencies = TRUE, ask = FALSE)'

# ---------------------------------------------------------------------------
# Build and install arbor itself
# ---------------------------------------------------------------------------
COPY . .
RUN R CMD INSTALL --no-multiarch --with-keep.source .

# Drop the build tree; the package is installed into the R library.
WORKDIR /work
RUN rm -rf /pkg

# Sanity check: package loads and its example dataset is present.
RUN Rscript -e 'library(arbor); stopifnot(nzchar(system.file("extdata", "9x9.laz", package = "arbor")))'

CMD ["R"]
