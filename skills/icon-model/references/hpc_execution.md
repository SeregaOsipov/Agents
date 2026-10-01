# ICON HPC Execution Guide

## Filesystem Architecture
When running on an HPC (e.g., AWS ParallelCluster):
- **Source Code & Scripts:** Store on the backed-up NFS user home directory (`/home/$USER/`).
- **Heavy I/O & Simulations:** All execution directories, raw NetCDF outputs, and intermediate datasets MUST reside on the high-throughput parallel filesystem (e.g., `/shared/scratch/`). Never run intensive I/O under `/home/`.

## Running Simulations via Slurm
A typical ICON run script is an SBATCH script that configures the environment (loading modules, setting stack sizes) and executes the ICON binary.
* **Important:** Ensure `ulimit -s unlimited` and thread stack sizes (`OMP_STACKSIZE`, `I_MPI_THREAD_STACK_SIZE`) are set to prevent memory crashes.

### Ensemble Execution (Slurm Arrays)
To run multiple members of an ensemble concurrently, utilize Slurm Job Arrays (`#SBATCH --array=1-N`).
* In your array script, use `SLURM_ARRAY_TASK_ID` to dynamically set the working directory for each member (e.g., `member_$(printf "%03d" $SLURM_ARRAY_TASK_ID)`).
* Change into the member's directory and execute the run script from there.

## Namelist Configuration Rules
* **Restarts:** If continuing a simulation, ensure `lresume = .TRUE.` in the `run_nml` and physically symlink the required restart NetCDF file into the run directory.
* **Grid Modes:** 
  * Global grids usually have a `_G` suffix (e.g., `icon_grid_0024_R02B06_G.nc`).
  * If running in Global Mode, ensure `dynamics_parent_grid_id = "0"` and no lateral boundary conditions (`latbc`) are specified.
  * If running in LAM (Limited Area Model) mode, lateral boundary conditions must be provided, and `rlam_heat` or `is_lam` parameters are typically active.
