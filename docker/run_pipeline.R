#!/usr/bin/env Rscript

# Run the full arbor pipeline on a raycloudtools .ply file.
#
# Usage:
#   Rscript run_pipeline.R <input.ply> <output_dir> [decimation_fraction]
#
# raycloudtools writes binary_little_endian PLY with double x/y/z, a `time`
# field, float nx/ny/nz (offset from the point back to the sensor origin) and
# uchar r/g/b/a. lidR cannot read .ply, so we parse it directly and build a
# LAS object in memory.

suppressPackageStartupMessages({
  library(lidR)
  library(arbor)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2L)
  stop("Usage: run_pipeline.R <input.ply> <output_dir> [decimation_fraction]")

ply_path <- args[[1]]
out_dir  <- args[[2]]
frac     <- if (length(args) >= 3L) as.numeric(args[[3]]) else 1.0

stopifnot(file.exists(ply_path))
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# ---------------------------------------------------------------------------
# Minimal binary-PLY reader (little-endian, one `element vertex` block)
# ---------------------------------------------------------------------------
read_binary_ply <- function(path) {
  con <- file(path, "rb")
  on.exit(close(con))

  probe  <- readBin(con, "raw", n = 8192L)
  marker <- charToRaw("end_header\n")
  find_raw <- function(hay, need) {
    n <- length(need); L <- length(hay)
    if (L < n) return(-1L)
    for (i in which(hay[seq_len(L - n + 1L)] == need[[1L]]))
      if (all(hay[i:(i + n - 1L)] == need)) return(i)
    -1L
  }
  m <- find_raw(probe, marker)
  if (m < 0L) stop("Could not find 'end_header' in the first 8 KB of the file")
  header_bytes <- m + length(marker) - 1L
  header       <- rawToChar(probe[seq_len(m - 1L)])   # header is pure ASCII
  lines        <- strsplit(header, "\n", fixed = TRUE)[[1]]

  if (!any(grepl("binary_little_endian", lines)))
    stop("Only binary_little_endian PLY is supported")

  n_el <- as.numeric(sub(".*element vertex\\s+([0-9]+).*", "\\1",
                         grep("element vertex", lines, value = TRUE)))

  ply_sizes <- c(char = 1L, uchar = 1L, int8 = 1L, uint8 = 1L,
                 short = 2L, ushort = 2L, int16 = 2L, uint16 = 2L,
                 int = 4L, uint = 4L, int32 = 4L, uint32 = 4L,
                 float = 4L, float32 = 4L, double = 8L, float64 = 8L)
  is_real   <- function(t) t %in% c("float", "float32", "double", "float64")
  is_uint   <- function(t) grepl("^u", t)

  pl <- grep("^property ", lines, value = TRUE)
  props <- lapply(strsplit(pl, "\\s+"), function(p) list(type = p[[2]], name = p[[3]]))
  types  <- vapply(props, `[[`, "", "type")
  names_ <- vapply(props, `[[`, "", "name")
  sizes  <- unname(ply_sizes[types])
  if (anyNA(sizes)) stop("Unsupported PLY property type: ",
                         paste(types[is.na(sizes)], collapse = ", "))
  offs   <- c(0L, cumsum(sizes))
  stride <- offs[length(offs)]

  seek(con, where = header_bytes, origin = "start")
  raw_all <- readBin(con, "raw", n = stride * n_el)
  if (length(raw_all) < stride * n_el)
    stop("File shorter than header claims (truncated?)")
  dim(raw_all) <- c(stride, n_el)

  get_col <- function(nm) {
    i  <- match(nm, names_)
    sz <- sizes[[i]]
    readBin(as.vector(raw_all[offs[[i]] + seq_len(sz), , drop = FALSE]),
            what = if (is_real(types[[i]])) "double" else "integer",
            size = sz, n = n_el, signed = !is_uint(types[[i]]),
            endian = "little")
  }

  list(get = get_col, names = names_, n = n_el)
}

message(sprintf("[%s] reading %s", format(Sys.time(), "%H:%M:%S"), ply_path))
ply <- read_binary_ply(ply_path)
message(sprintf("  %s points, fields: %s",
                format(ply$n, big.mark = ","), paste(ply$names, collapse = ", ")))

dt <- data.table::data.table(X = ply$get("x"), Y = ply$get("y"), Z = ply$get("z"))
rm(ply); invisible(gc())

if (is.finite(frac) && frac > 0 && frac < 1) {
  keep <- sample.int(nrow(dt), size = floor(nrow(dt) * frac))
  dt <- dt[sort(keep)]
  message(sprintf("  decimated to %s points (fraction %.2f)",
                  format(nrow(dt), big.mark = ","), frac))
}

message(sprintf("  X: [%.2f, %.2f]  Y: [%.2f, %.2f]  Z: [%.2f, %.2f]",
                min(dt$X), max(dt$X), min(dt$Y), max(dt$Y), min(dt$Z), max(dt$Z)))

las <- lidR::LAS(dt, check = FALSE)
# Coordinates arrive as doubles, from which lidR infers an unusable 1e-8 scale
# factor. Force a standard 1 mm scale so the result round-trips through LAS/LAZ.
las <- lidR::las_rescale(las, 0.001, 0.001, 0.001)
rm(dt); invisible(gc())
# If your raycloud is georeferenced (e.g. GDA2020 / MGA zone 55) set it here:
# lidR::st_crs(las) <- 7855

# ---------------------------------------------------------------------------
# arbor pipeline (see the Minimal Reproducible Example in README.md)
# ---------------------------------------------------------------------------
step <- function(msg, expr) {
  t0 <- Sys.time()
  message(sprintf("[%s] %s ...", format(t0, "%H:%M:%S"), msg))
  val <- force(expr)
  message(sprintf("    done in %.1f s", as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  val
}

las <- step("hybrid_homogeneization", hybrid_homogeneization(las))
las <- step("segment_ground",         segment_ground(las))
las <- step("wood_likelihood",        wood_likelihood(las))
las <- step("segment_semantic",       segment_semantic(las))
see <- step("find_seeds",             find_seeds(las))
message(sprintf("    %d seed(s) found", nrow(see)))
las <- step("segment_instance",       segment_instance(las, see))
las <- step("flag_buffer",            flag_buffer(las, see, -0.75))
las <- step("flag_small_trees",       flag_small_trees(las, 1))
qsf <- step("qsf",                    qsf(las))
message(sprintf("    %d QSM(s) built", length(qsf)))

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
base <- tools::file_path_sans_ext(basename(ply_path))

# QSF outputs first - they are the point of the run.
qsm_dir <- file.path(out_dir, paste0(base, "_qsm"))
dir.create(qsm_dir, showWarnings = FALSE)
step(paste("write QSMs ->", qsm_dir),
     qsf_write(qsf, qsm_dir, formats = c("qsm", "ply", "csv")))

treemap <- qsf_treemap(qsf)
tm_file <- file.path(out_dir, paste0(base, "_treemap.gpkg"))
step(paste("write", tm_file),
     try(sf::st_write(treemap, tm_file, delete_dsn = TRUE, quiet = TRUE), silent = TRUE))
utils::write.csv(sf::st_drop_geometry(treemap),
                 file.path(out_dir, paste0(base, "_treemap.csv")), row.names = FALSE)

seg_las <- file.path(out_dir, paste0(base, "_segmented.laz"))
step(paste("write", seg_las), lidR::writeLAS(las, seg_las))

message(sprintf("[%s] finished. Outputs in %s",
                format(Sys.time(), "%H:%M:%S"), normalizePath(out_dir)))
