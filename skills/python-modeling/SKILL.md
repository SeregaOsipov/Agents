---
name: python-modeling
description: Runbook for Python workflows in environmental and atmospheric modeling (WRF, ICON, CAMS). Enforces environment activation via gogomamba, package management with mamba over pip, and data handling with xarray, xoak, and netCDF.
---

# Python for Environmental & Atmospheric Modeling

This skill provides operational standards for developing and running Python workflows in atmospheric and environmental modeling on HPC clusters and cloud instances.

> **CRITICAL INSTRUCTION (Path Parameterization & Asking Rule):**
> Never hardcode user home paths or mounts. Use parameterized paths (`${HOME}`, `${SCRATCH}`, `${DATA_ROOT}`).
> If any required environment script, repository path, or directory is undefined or ambiguous, **prompt and ask the user** before proceeding.

---

## 1. Environment Activation (`gogomamba`)

Always activate the designated scientific Python environment through the user environment loader:

```bash
# Sourcing environment and initializing mamba
source "${ENV_SCRIPT:-$HOME/.commonrc}"
gogomamba

# Target environment default is py311 (or activate custom if needed)
mamba activate "${CONDA_ENV:-py311}"
```

### Slurm Jobs & Subshells
In batch scripts (`.slurm`, `.sh`) and Python subshells (`subprocess.run`), explicitly source the loader:

```bash
#!/bin/bash
source "${ENV_SCRIPT:-$HOME/.commonrc}"
gogomamba
mamba activate "${CONDA_ENV:-py311}"
```

---

## 2. Package Management: Mamba-First Policy

Environmental modeling relies on native C/Fortran shared libraries (`libnetcdf`, `eccodes`, `hdf5`, `proj`, `geos`). Mixing `pip` can cause binary ABI incompatibilities.

* **Primary (`mamba`)**: Always install packages via conda-forge:
  ```bash
  mamba install -c conda-forge <package-name>
  ```
* **Secondary (`pip`)**: Only use `pip` if the package is unavailable on conda-forge or for local repository editable development:
  ```bash
  pip install -e .
  ```
* **No ad-hoc environments**: Do not create throwaway virtualenvs in `$HOME`. Parameterize environment paths under `${MINIFORGE_DIR:-$HOME/apps/miniforge3}/envs/`.

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
