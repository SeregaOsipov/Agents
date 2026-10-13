---
name: icon-model
description: >-
  Use this skill when the user asks you to configure, execute, or analyze the ICON (Icosahedral Non-hydrostatic) atmospheric model. This includes deploying single simulations or ensembles on AWS or Slurm-based HPC clusters, configuring namelists, and processing ICON's native unstructured NetCDF outputs.
---

# ICON Model Execution & Analysis

This skill serves as the primary runbook for configuring and executing the ICON atmospheric model on HPC environments, and for handling its unique unstructured outputs.

## Execution Steps

Follow these steps when preparing or deploying an ICON simulation:

1. **Configure the Environment (Python-First Workflow)**
   Do not manually edit execution templates. Instead, modify the centralized `ensemble_config.ini` file and execute the relevant Python setup script (e.g., `setup_free_run.py` or `setup_ensemble.py`). These scripts will automatically utilize `ClimPy` to safely patch variables and bootstrap the Lustre `/shared` output directories.
   👉 *Reference:* [Python Configuration Workflow](./references/python_configuration.md)
   👉 *Reference:* [HPC Execution & Slurm Setup](./references/hpc_execution.md)

2. **Validate the Configuration**
   Before submitting to Slurm, run the validation helper script against your target run directory to ensure symlinks and inputs are structurally sound.
   ```bash
   ./scripts/validate_icon_setup.sh /path/to/target/run/directory
   ```

3. **Submit the Job**
   Submit the rendered SBATCH script (e.g., `sbatch run_free_run.slurm`). If deploying an ensemble, ensure the setup script correctly populated the Slurm array bounds.

4. **Validate Success (Post-Run)**
   Do not assume a `0` exit code means the model ran successfully. 
   - Tail the `output.txt` and `error.txt` files inside the run directory.
   - **Verification:** Ensure there are no segmentation faults or memory allocation errors. A successful run will output "clean exit" or finish its final integration step at the bottom of the log.

## Post-Processing Steps

1. **Handle Time-Level Parity**
   When extracting state vectors from the generated NetCDF files using Python, dynamically check for `.TL1` or `.TL2` suffixes. Do not hardcode the suffix.
2. **Map the Unstructured Grid**
   If mapping observation coordinates to the native unstructured grid, convert to 3D Cartesian coordinates and use `scipy.spatial.cKDTree`. Do NOT use `uxarray.Grid.get_spatial_hash()`.
   👉 *Reference:* [Grid Mapping & Processing](./references/grid_mapping.md)


## IFS Initialization (`INIT_MODE=2`) Gotchas

When generating Initial Conditions (IC) from non-DWD sources (like ECMWF CAMS or ERA5 via CDS API) for `INIT_MODE=2`, ICON is extremely rigid. Follow these fixes to avoid obscure crashes:

1. **The 2.1 Billion Level OOM Bug:** ICON strictly expects the vertical dimension of 3D variables to be named `lev` or `height`. If it is named `model_level` (e.g. from CDO remapping), a bug in `mo_initicon_io.f90` sets the number of levels to `HUGE(1)`, instantly triggering a `severe (41): insufficient virtual memory` crash as every MPI task attempts to allocate 2.1 billion levels. Use `ncrename` or `netCDF4` to rename the dimension to `lev`.
2. **Missing Hybrid Coefficients (`hyai`/`hybi`):** CDS API's NetCDF conversion (via `cfgrib`) drops the 137-level `hyai` and `hybi` arrays, causing an `Invalid dimension ID or name` error for `nhyi`. You can extract these back from the hidden `GRIB_pv` attribute attached to the variables, and inject them explicitly into the IC file.
3. **Hardcoded Uppercase Variables:** `mo_initicon_io.f90` expects uppercase names for standard meteorology. You must rename variables like `t`->`T`, `u`->`U`, `sp`->`PS`, `q`->`QV` before ICON will read them. CDO's `chname` is the fastest way to do this for large files.
4. **Surface Geopotential (`GEOSP`):** If missing, ICON aborts. You can construct this by reading `topography_c` from the grid's `extpar` file and multiplying it by `9.80665`, then injecting it as `GEOSP(time, cell)`.
5. **Soil Properties Dimensions:** When reading `STL1..4` or `SMIL1..4`, ICON strictly expects a 3-dimensional array `(time, depth, cell)`, even if `depth` is size 1. A 2D array will crash with a `Dimensions mismatch` error.

## Restart Initialization (`lRestart = .true.`) Gotchas

When conducting data assimilation cycling or simply restarting an interrupted ICON run, ICON enforces an extremely strict metadata validation check between the namelist parameters and the internal NetCDF attributes of the restart file:

1. **`experimentStartDate` vs `tc_startdate`:** In `icon_master.namelist`, `experimentStartDate` controls the `INI_DATETIME_STRING`. This must **never** be advanced during restarts. It must permanently match the exact initialization date of the original unassimilated baseline experiment from which the first background restart file was generated.
2. **Metadata Mismatch Abort:** If `experimentStartDate` is mistakenly set to the current cycle's physical start time instead of the original baseline start time, ICON detects that the `INI_DATETIME_STRING` in the namelist does not match the deeply embedded original string tracked inside the NetCDF restart file. This triggers an immediate `Error in conversion of start date` and an `Abort(1)` crash.
3. **Safe Restarting:** Always leave `experimentStartDate` anchored to the true beginning of the simulation block (e.g., `2019-06-22T00:00:00Z`). When `lRestart = .true.` is active, ICON ignores `experimentStartDate` for physics integration and dynamically resumes exactly from the physical checkpoint time (`tc_startdate`) stored in the restart file, preserving unbroken metadata continuity.

## Multi-Cloud Portability & Cluster Independence (AWS & Azure)

When running ICON across cloud providers (e.g. migrating from AWS ParallelCluster to Microsoft Azure CycleCloud):

1. **Slurm Process Manager (PMI2) Path:**
   - AWS ParallelCluster installs Slurm at `/opt/slurm/lib/libpmi2.so`.
   - Azure CycleCloud installs Slurm at `/sched/slurm/lib/libpmi2.so` (or Linux distribution defaults `/usr/lib64/slurm/libpmi2.so`).
   - In model launch scripts, auto-discover `I_MPI_PMI_LIBRARY` dynamically across `/sched/slurm/`, `/opt/slurm/`, and `/usr/lib64/slurm/`, or export `SLURM_PMI_LIB`.
2. **MPI Process Geometry:**
   - Avoid hardcoding `-np 32`. Use `${SLURM_NTASKS:-32}` to adapt to high-density Azure HPC nodes (e.g., AMD EPYC `HB120-16rs_v3` with 120 cores per node vs. AWS `c6i` with 32 cores).
3. **Environment & Path Resolution:**
   - Never hardcode `/home/<user>` or `/shared/scratch/<user>`. Use environment variable expansion (`${USER}`, `${HOME}`, `${SCRATCH_ROOT}`).
   - Parameterize cluster environment loaders via `CLUSTER_ENV_SCRIPT` rather than hardcoding user-specific rc files (`~/.commonrc`).
4. **Cloud Object Storage:**
   - Use the generic cloud storage abstraction (`cloud_storage.py`) supporting Azure Blob Storage (via **Azure Managed Identity - AZM** / `DefaultAzureCredential`), AWS S3, and POSIX filesystems to stage inputs and archive simulation outputs.
