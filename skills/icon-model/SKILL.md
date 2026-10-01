---
name: icon-model
description: >-
  Use this skill when the user asks you to configure, execute, or analyze the ICON (Icosahedral Non-hydrostatic) atmospheric model. This includes deploying single simulations or ensembles on AWS or Slurm-based HPC clusters, configuring namelists, and processing ICON's native unstructured NetCDF outputs.
---

# ICON Model Execution & Analysis

This skill provides the operational runbook for configuring and executing the ICON atmospheric model (and ICON-ART) on HPC environments, as well as handling its unique unstructured outputs.

## 1. Filesystem & Storage Architecture

When running on an HPC (e.g., AWS ParallelCluster):
- **Source Code & Scripts:** Should reside on the backed-up NFS user home directory (e.g., `/home/$USER/Models/icon-model/`).
- **Heavy I/O & Simulations:** All execution directories, raw NetCDF outputs, and intermediate datasets **MUST** reside on the high-throughput parallel filesystem (e.g., `/shared/scratch/`). Never run intensive I/O under `/home/`.

## 2. Running Simulations via Slurm

### Single Simulation
A typical ICON run script (e.g., `exp.testsuite.dust_rad_base`) is an SBATCH script that configures the environment (loading modules, setting stack sizes) and executes the ICON binary.
* **Important:** Ensure `ulimit -s unlimited` and thread stack sizes (`OMP_STACKSIZE`, `I_MPI_THREAD_STACK_SIZE`) are set to prevent memory crashes.

### Ensemble Execution (Slurm Arrays)
To run multiple members of an ensemble concurrently, utilize Slurm Job Arrays (`#SBATCH --array=1-N`).
* In your array script, use `SLURM_ARRAY_TASK_ID` to dynamically set the working directory for each member (e.g., `member_$(printf "%03d" $SLURM_ARRAY_TASK_ID)`).
* Change into the member's directory and execute the run script from there.

## 3. Namelist Configuration Rules

* **Restarts:** If continuing a simulation, ensure `lresume = .TRUE.` in the `run_nml` and physically symlink the required restart NetCDF file into the run directory.
* **Grid Modes:** 
  * Global grids usually have a `_G` suffix (e.g., `icon_grid_0024_R02B06_G.nc`).
  * If running in Global Mode, ensure `dynamics_parent_grid_id = "0"` and no lateral boundary conditions (`latbc`) are specified.
  * If running in LAM (Limited Area Model) mode, lateral boundary conditions must be provided, and `rlam_heat` or `is_lam` parameters are typically active.

## 4. Processing ICON Output Data

### Unstructured Grid Mapping
ICON operates natively on an **unstructured icosahedral grid** consisting of triangular cells.
> [!WARNING]
> Do NOT use `uxarray.Grid.get_spatial_hash()` for mapping spherical coordinates (`[lon, lat]`), as it contains a critical bug that can mirror coordinates to the opposite side of the globe.
* **Best Practice:** Convert surface coordinates to 3D Cartesian `[x, y, z]` coordinates and use strictly `scipy.spatial.cKDTree` to map observation locations directly to the native unstructured grid indices.

### Time Level (TL) Parity
ICON's non-hydrostatic dynamical core utilizes a two-time-level integration scheme. 
* Prognostic variables (e.g., `rho`, `vn`, `t_g`) saved in restart files will alternate between `.TL1` and `.TL2` suffixes depending on whether the absolute time step parity is even or odd.
* **Dynamic Resolution:** Python postprocessing scripts must *dynamically* check the NetCDF variables (e.g., using `if "rho.TL2" in ds:`) rather than hardcoding `.TL1` or `.TL2`. If both are detected simultaneously for the same physical field, your code should throw a deliberate error.
* **ART Tracers:** Note that some ICON-ART prognostic tracers (e.g., `dusta`, `dustb`) may bypass this parity and natively save as `.TL2`, but dynamic suffix resolution must remain active globally to ensure robust I/O.
