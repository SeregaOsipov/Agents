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

