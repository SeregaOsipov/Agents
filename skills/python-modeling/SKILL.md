---
name: python-modeling
description: Runbook for Python workflows in environmental and atmospheric modeling (WRF, ICON, CAMS). Enforces environment activation via gogomamba, package management with mamba over pip, and data handling with xarray, xoak, and netCDF.
---

# Python for Environmental & Atmospheric Modeling

This skill provides operational standards for developing and running Python workflows in atmospheric and environmental modeling on HPC clusters and cloud instances.

> [!CRITICAL]
> **DEDICATED ENVIRONMENT RULE (NO SYSTEM PYTHON):**
> **NEVER** use, install into, or modify the host OS system Python (`/usr/bin/python3`, `/usr/lib/python3*`, or `--user` installations under `~/.local` tied to system Python).
> All modeling tools, workflows, batch scripts, and Fortran/C Python extensions **MUST** run within a dedicated Conda/Mamba environment.
> The standard modeling environment is **`py312`**, initialized via `gogomamba` in `~/.commonrc`.

> **CRITICAL INSTRUCTION (Path Parameterization & Asking Rule):**
> Never hardcode user home paths or mounts. Use parameterized paths (`${HOME}`, `${SCRATCH}`, `${DATA_ROOT}`).
> If any required environment script, repository path, or directory is undefined or ambiguous, **prompt and ask the user** before proceeding.

---

## 1. Environment Activation (`gogomamba` & `py312`)

Always activate the designated scientific Python environment through the user environment loader:

```bash
# Sourcing environment and initializing mamba
source "${ENV_SCRIPT:-$HOME/.commonrc}"
gogomamba

# Target environment default is py312 (or activate project-specific env if needed)
mamba activate "${CONDA_ENV:-py312}"
```

### Slurm Jobs & Subshells
In batch scripts (`.slurm`, `.sh`) and Python subshells (`subprocess.run`), explicitly source the loader:

```bash
#!/bin/bash
source "${ENV_SCRIPT:-$HOME/.commonrc}"
gogomamba
mamba activate "${CONDA_ENV:-py312}"
```

---

## 2. Package Management: Mamba-First Policy

Environmental modeling relies on native C/Fortran shared libraries (`libnetcdf`, `eccodes`, `hdf5`, `proj`, `geos`). Mixing system pip can cause severe ABI incompatibilities and host contamination.

* **Dedicated Environments Only**: Environments reside under `${MINIFORGE_DIR:-/scratch/p26002/sosipov/apps/miniforge3}/envs/` or `${CONDA_ENVS_DIR}`. System Python must remain completely untouched.
* **Primary (`mamba`)**: Always install packages via conda-forge:
  ```bash
  mamba install -n "${CONDA_ENV:-py312}" -c conda-forge <package-name>
  ```
* **Secondary (`pip`)**: Only use `pip` if the package is unavailable on conda-forge or for compiling local repository extensions (e.g. `pyPDAF`, `mpi4py` against cluster Intel MPI):
  ```bash
  # ALWAYS ensure the dedicated environment is active before running pip
  mamba activate "${CONDA_ENV:-py312}"
  pip install --no-deps --no-build-isolation -e .
  ```
* **No ad-hoc virtualenvs**: Do not create throwaway virtualenvs or pip user-installs in `$HOME/.local`.

---

## 3. Core Geospatial & Modeling Libraries

### `xarray` (Primary Data Model)
* Use `xarray.Dataset` / `DataArray` for all NetCDF and GRIB operations.
* Preserve CF conventions, coordinates (`lat`, `lon`, `time`, `level`), and staggered grid coordinates (`bottom_top_stag`, `south_north_stag`).
* Use `dask` chunking when dealing with large 3D/4D atmospheric fields (e.g. 137 vertical model levels from CAMS or high-resolution ICON grids):
  ```python
  import xarray as xr
  ds = xr.open_dataset(nc_path, chunks={"time": 1, "level": 10})
  ```

### `xoak` (Unstructured & Curvilinear Indexing)
* Standard rectilinear xarray indexing fails on irregular grids (WRF 2D `XLAT`/`XLONG`, ICON geodesic triangular cells, satellite swaths like TROPOMI).
* Use `xoak` with KD-tree / BallTree indexes for fast spatial lookups:
  ```python
  import xoak
  ds = xr.open_dataset(wrf_or_emissions_path)
  ds.xoak.set_index(["XLAT", "XLONG"], "sklearn_geo_balltree")
  ```

### Direct I/O & Formats
* **NetCDF4**: `netCDF4.Dataset` for in-place binary mutations (e.g. `cams2wrf` updating `wrfinput`/`wrfbdy`).
* **GRIB / GRIB2**: `eccodes` and `cfgrib` (or `wgrib2` CLI for batch preprocessing).
* **Regridding**: `scipy.interpolate` (`RectBivariateSpline`, `interp1d`) and CDO (`cdo-python` or `cdo remapcon`).

---

## 4. Workspace Repositories & `PYTHONPATH`

Key workspace utilities must be referenced via parameterized environment variables:

| Variable | Description | Default / Example Location |
| :--- | :--- | :--- |
| `$CLIMPY_DIR` | ClimPy environmental utilities library | `${HOME}/workspace/ClimPy` |
| `$MERRA2BC_DIR` | Initial & boundary condition generator | `${HOME}/workspace/Merra2BC` |

When calling scripts from these repositories, ensure `PYTHONPATH` includes both packages:
```bash
export PYTHONPATH="${CLIMPY_DIR}:${MERRA2BC_DIR}:${PYTHONPATH}"
python -u "${MERRA2BC_DIR}/cams2wrf_main.py" ...
```

---

## 5. Platform-Independent Configuration Architecture

Python modeling frameworks should strictly separate scientific domain definitions from cluster platform infrastructure:

1. **Model Configuration (`config/models/*.yaml`)**: Contains domain dimensions, physics options, chemical mechanisms, cycle dates, and relative input paths.
2. **Cluster Platform Configuration (`config/clusters/*.yaml`)**: Contains cluster filesystem mounts (`scratch_dir`, `data_dir`), Slurm scheduler specifications (partitions, node counts, tasks per node), environment module activations, and MPI runtime flags (`I_MPI_DEBUG` vs `UCX_NET_DEVICES`).
3. **Unified Loader (`config_loader.py`)**: Merges model and cluster YAMLs at runtime, injecting platform base paths into `${SCRATCH}` and `${DATA_DIR}` so the scientific model configuration remains 100% cloud- and platform-agnostic.
