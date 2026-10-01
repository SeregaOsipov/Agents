---
name: icon-model
description: >-
  Use this skill when the user asks you to configure, execute, or analyze the ICON (Icosahedral Non-hydrostatic) atmospheric model. This includes deploying single simulations or ensembles on AWS or Slurm-based HPC clusters, configuring namelists, and processing ICON's native unstructured NetCDF outputs.
---

# ICON Model Execution & Analysis

This skill serves as the primary runbook for configuring and executing the ICON atmospheric model on HPC environments, and for handling its unique unstructured outputs.

## Execution & Configuration Checklist

When tasked with setting up or debugging an ICON simulation, consult the following references:

1. **HPC Execution & Slurm Setup**
   Ensure you are using the correct filesystems (`/shared` vs `/home`), properly configuring Slurm arrays for ensembles, and avoiding memory crashes with the correct `ulimit`.
   👉 [Read the HPC Execution Reference](./references/hpc_execution.md)

2. **Unstructured Data Mapping & Parity**
   If you need to process or map data to ICON's native unstructured icosahedral grids, you **must** avoid `uxarray` and handle the two-time-level (`.TL1`/`.TL2`) integration parity correctly.
   👉 [Read the Grid Mapping & Processing Reference](./references/grid_mapping.md)

## Example Templates

*   [Slurm Execution Script Example](./examples/exp.testsuite.dust_rad_base.txt)

