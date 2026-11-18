---
name: palm4u
description: >-
  Use this skill when configuring, compiling, executing, or debugging the PALM-4U (Parallelized Large-Eddy Simulation Model for Urban Applications, v25.10.1+) urban microscale atmospheric and chemistry/aerosol (phstatp + SALSA + RRTMG) modeling system driven by mesoscale WRF-Chem forecasts. Covers public release acquisition, Intel oneAPI compilation (mpiifx + RRTMG + NetCDF4), SALSA aerosol-chemistry coupling patches, WRF-Chem to PALM dynamic driver conversion (PIDS_DYNAMIC), mass-conserving lateral/top boundary conditions, and MPI execution. All paths are parameterized; ask the user for any missing paths.
---

# PALM-4U Urban Microscale Execution & WRF-Chem Coupling

This skill serves as the primary operational runbook for compiling, configuring, and running **PALM-4U** (release `v25.10.1`) urban microscale simulations coupled offline to mesoscale **WRF-Chem** forecasts.

> **CRITICAL AGENT INSTRUCTION (Path Parameterization & Interactive Disambiguation):**
> All paths in this runbook are parameterized and platform-independent. **Do NOT assume hardcoded user paths or cluster mounts** (such as `/home/username` or specific `/scratch` mounts) when deploying to a new system.
>
> **Before executing or generating scripts for any step**, verify that the necessary paths are defined in the active YAML configuration (`config/models/palm_*.yaml`), environment variables, or user context.
> **If any path is missing, not defined, or ambiguous, YOU MUST PROMPT AND ASK THE USER for the path rather than making assumptions.**

---

## Environment Variables & Path Glossary

| Variable | Description | Typical / Example Location |
| :--- | :--- | :--- |
| `$PALM_ROOT` | Official PALM-4U release source root (`v25.10.1`) | `${HOME}/Models/palm_model_system-v25.10.1` |
| `$PALM_BUILD_DIR` | Compiled PALM-4U depository (`palm`, `rrtmg/rrtmg.so`, `combine_plot_fields.x`) | `${PALM_ROOT}/packages/palm/model/build/MAKE_DEPOSITORY_default` |
| `$PALM_WORK_DIR` | Working scratch directory for PALM-4U operational cycles | `${WORK_DIR}/PALM_run/operational_forecast` |
| `$PALM_STATIC_FILE` | PIDS-compliant PALM static driver (`_static` NetCDF with topography, buildings, pavement, vegetation, soil, street types) | `${WORK_DIR}/PALM_run/static/DohaForecast_19km_100m_static` (or `DohaForecastChem_static`) |
| `$PALM_SLURB_FILE` | PIDS SLUrb urban-canopy driver (`_slurb` NetCDF, required for `100 m` SLUrb tier) | `${WORK_DIR}/PALM_run/static/DohaForecast_19km_100m_slurb` |
| `$WRF_OUTPUT_DIR` | Directory containing parent `wrfout_d02_*` (`2 km`, preferred) or `wrfout_d01_*` (`10 km`) files | `${WORK_DIR}/WRF_run/operational_forecast/ag_weekly_7day_cycle` |
| `$NETCDF_FORTRAN_ROOT` | Intel-compiled NetCDF C/Fortran installation prefix | `${HOME}/WRF_LIBS/intel` |
| `$ENV_SCRIPT` | HPC environment / module loader script | `${HOME}/.commonrc` |
| `$MODULE_ENV_CMD` | Environment initialization command or alias | `gogowrfchem` |

### Active Doha Multi-Scale Tiers
- **Tier 3 — `100 m` Urban SLUrb (`config/models/palm_doha_100m.yaml`, default active tier)**:
  - Domain: `192 × 192 × 32` (`nx=191, ny=191, nz=32`), `dx = dy = 100 m`, `dz = 25 m` uniform (top `800 m` AGL).
  - Physics: SLUrb parameterized urban canopy (`PIDS_SLURB`, `&slurb_parameters`) + RRTMG + biometeorology + `phstatp` + 7-species `SALSA` + `1-minute` (`60 s`) output (`npex = 6, npey = 4` = `24` MPI ranks).
- **Tier 4 — `10 m` Building-Resolving LES (`config/models/palm_doha_10m.yaml` / `palm_doha_chem.yaml`)**:
  - Domain: `200 × 200 × 48` (`nx=199, ny=199, nz=48`), `dx = dy = 10 m`, `dz = 3 m` stretched (`1.20`) above `51 m` to `dz_max = 30 m`.
  - Physics: USM + PCM (`&plant_canopy_parameters`) + RRTMG + `phstatp` + 7-species `SALSA` + `1-minute` (`60 s`) output (`npex = 5, npey = 5` = `25` MPI ranks). Can be chained after `100 m` via comma-separated `PALM_MODEL_CONFIGS`.

---

## 1. Acquiring & Compiling Official PALM-4U (`v25.10.1`)

### A. Public Tarball Acquisition (No GitLab Account Required)
`gitlab.palm-model.org` prompts for credentials on HTTPS `git clone`, but official release archives are publicly downloadable without authentication:
```bash
curl -fL "https://gitlab.palm-model.org/releases/palm_model_system/-/archive/v25.10.1/palm_model_system-v25.10.1.tar.gz" \
  -o /tmp/palm_model_system-v25.10.1.tar.gz
tar -xzf /tmp/palm_model_system-v25.10.1.tar.gz -C "$(dirname "${PALM_ROOT}")"
```

### B. Required Source & Build Patches for `v25.10.1`
Before compiling PALM-4U `v25.10.1` with SALSA aerosol physics, gas-phase chemistry, RRTMG radiation, and modern CMake (`>= 4.0`):

1. **CMake 4.x Compatibility & Preprocessor Macros (`packages/palm/model/share/cmake/CMakeLists.txt`)**:
   - Update `cmake_minimum_required (VERSION 2.8)` to `cmake_minimum_required (VERSION 3.5)`.
   - Ensure `list(APPEND PALM_CPP_OPTIONS __netcdf4)` is added inside `if(NETCDF)` so NetCDF-4 parallel/chunked output routines (`data_output_netcdf4_module.f90`) are compiled.
2. **SALSA, Absolute Input & SLUrb Nighttime Patches (`config/palm/patches/salsa/` and `config/palm/patches/salsa_absolute/`)**:
   - Apply the audited patches into `${PALM_ROOT}/packages/palm/model/src/` (and register `salsa_absolute_input_mod.f90` in `Makefile`):
     - `salsa_absolute_input_mod.f90` + `salsa_mod.f90`: Implement `absolute_mass_number_v1` NetCDF ingestion (`salsa_absolute_mass_input`, `salsa_allow_research_input`) for independent 10-bin aerosol number (`#/m³`) and 7-species dry mass (`kg/m³`), drive SALSA alongside `phstatp` (`salsa_independent_gases = .TRUE.`), bound concentrations, and fix sectional boundary indexing in `salsa_nesting_offl_bc` without stdout `WRITE(*,*)` spam.
     - `slurb_mod.f90` (`calc_rad_sw`): Guard `surf%albedo_urb(m) = surf%rad_sw_out_urb(m) / surf%rad_sw_in_urb(m)` behind `IF ( surf%rad_sw_in_urb(m) > 0.0_wp )` to prevent `0/0` NaN blow-up during nighttime SLUrb cycles.
     - `advec_ws.f90` (`ws_init_flags_scalar`): Clear and recompute southern non-cyclic scalar advection flags from atmospheric `topo_flags(k,nys,i)` bit 2 (`advc_flag(k,nys-1,i)`).
     - `netcdf_data_input_mod.f90`, `timestep.f90`, `time_integration.f90`: Support dynamic driver SALSA input and safe sub-stepping/BC updates during RK3 integration.
   - **Important (`bc_cs_t = 'dirichlet'` & Compiler Flags)**:
     - In `DohaForecastChem_p3d.template` (`&chemistry_parameters`), when offline chemistry nesting is enabled (`nesting_offline_chem = .TRUE.`) without domain-wide 3D nudging (`nudging = .FALSE.`), **always** set `bc_cs_t = 'dirichlet'` explicitly. If omitted, PALM defaults to `bc_cs_t = 'initial_gradient'` (`ibc_cs_t = 2`), which reads the uninitialized array `bc_cs_t_val` (only populated when `nudging = .TRUE.`) at `k = nzt + 1` on Runge-Kutta substep 1 (`chemistry_model_mod.f90:634`).
     - In `.palm.config.default`, compile with `-O2 -fp-model source -fno-alias -ftz -nbs -diag-disable 8290,8291` (do **not** enable `-fpe0` or `-O3 -no-prec-div`).
     - Do **not** include the literal substring `rrtmg` (e.g. `-Wl,-rpath,.../rrtmg`) inside `%compiler_options` or `%linker_options` in `.palm.config.default`, because `palmbuild` greps those lines for `rrtmg` and skips building the bundled `rrtmg.so` library if found. Instead, export `LD_LIBRARY_PATH="${PALM_BUILD_DIR}/rrtmg:${LD_LIBRARY_PATH}"` in `runPalm.sh`.

### C. Intel oneAPI (`mpiifx`) Build Configuration (`.palm.config.default`)
Configure `${PALM_ROOT}/packages/palm/model/build/.palm.config.default`:
```ini
%base_directory      ${PALM_ROOT}/packages/palm/model/build
%base_data           ${PALM_ROOT}/packages/palm/model/build/JOBS
%source_path         ${PALM_ROOT}/packages/palm/model/src
%user_source_path    ${PALM_ROOT}/packages/palm/model/build/JOBS/$run_identifier/USER_CODE
%fast_io_catalog     ${PALM_ROOT}/packages/palm/model/build/tmp
%restart_data_path   ${PALM_ROOT}/packages/palm/model/build/tmp
%output_data_path    ${PALM_ROOT}/packages/palm/model/build/JOBS
%local_jobcatalog    ${PALM_ROOT}/packages/palm/model/build/JOBS/$run_identifier/LOG_FILES
%local_ip            127.0.0.1
%local_hostname      fedora
%local_username      ${USER}
%c_compiler_name         /usr/bin/cc
%compiler_name           /opt/intel/oneapi/mpi/2021.18/bin/mpiifx
%compiler_name_ser       /opt/intel/oneapi/mpi/2021.18/bin/mpiifx
%cpp_options             -fpp -D__intel_compiler -D__parallel -DMPI_REAL=MPI_DOUBLE_PRECISION -DMPI_2REAL=MPI_2DOUBLE_PRECISION -D__netcdf -D__netcdf4 -D__rrtmg
%make_options            -j 56
%c_compiler_options      -Ofast -Wno-format -Wno-unused-result
%compiler_options_rrtmg  -O2 -fp-model source -fno-alias -ftz -nbs -diag-disable 8290,8291 -I ${NETCDF_FORTRAN_ROOT}/include
%compiler_options        -O2 -fp-model source -fno-alias -ftz -nbs -diag-disable 8290,8291 -I ${NETCDF_FORTRAN_ROOT}/include
%linker_options_rrtmg    -O2 -fp-model source -fno-alias -ftz -nbs -diag-disable 8290,8291 ${NETCDF_FORTRAN_ROOT}/lib/libnetcdff.so -L${NETCDF_FORTRAN_ROOT}/lib -lnetcdf
%linker_options          -O2 -fp-model source -fno-alias -ftz -nbs -diag-disable 8290,8291 ${NETCDF_FORTRAN_ROOT}/lib/libnetcdff.so -L${NETCDF_FORTRAN_ROOT}/lib -lnetcdf -Wl,-rpath,${NETCDF_FORTRAN_ROOT}/lib
%execute_command         mpirun -n {{mpi_tasks}} ./palm
```

### D. Building `rrtmg.so`, `palm`, and `combine_plot_fields.x`
1. **Full Build via `palmbuild`**:
   ```bash
   source /opt/intel/oneapi/setvars.sh --force
   cd "${PALM_ROOT}/packages/palm/model/build"
   ../bin/palmbuild -v -c default
   ```
2. **Fast Incremental Rebuild (When Modifying a Single `.f90` File)**:
   - Instead of re-running `palmbuild` (which re-copies and recompiles all 140+ files), copy only the modified `.f90` file into `${PALM_BUILD_DIR}/` and run `make -j 56 -C "${PALM_BUILD_DIR}" palm ...`.

---

## 2. WRF-Chem to PALM-4U Dynamic Driver Conversion (`_dynamic`)

Implemented in `src/oper_forecast/preprocessing/palm/wrf_to_palm_dynamic.py` (with conservative modal-to-sectional kernel in `salsa_remap.py`), supporting both `100 m` SLUrb (`palm_doha_100m.yaml`) and `10 m` building-resolving (`palm_doha_10m.yaml` / `palm_doha_chem.yaml`) tiers.

### A. Parent Domain Selection, Grid Mapping & Sub-Cropping
- Automatically selects `${WRF_OUTPUT_DIR}` **`wrfout_d02_*`** (`2 km`) when it encloses the PALM bounding box and covers the forecast window, falling back cleanly to **`wrfout_d01_*`** (`10 km`), and crops the WRF horizontal window around the PALM target box (`pad_cells = 3`).
- Reads grid geometry (`origin_x`, `origin_y`, `origin_z`, `origin_lat`, `origin_lon`, `rotation_angle`, `crs`) directly from `${PALM_STATIC_FILE}` and domain parameters (`nx`, `ny`, `nz`, `dx`, `dy`, `dz`, `dz_stretch_level`, `dz_stretch_factor`, `dz_max`) from YAML.
- Projects PALM staggered (`xu`, `yv`, `zw`) and cell-center (`x`, `y`, `z`) coordinates onto the WRF LCC grid, performing bilinear horizontal interpolation and vector wind rotation (`u`, `v`) to PALM local coordinates.

### B. Near-Ground Vertical Adaptation (`PALM-meteo` GMD 2026 Methodology)
- Reference: Krč et al. (2026), *PALM-meteo 2.8: Processor of PALM meteorological input data*, Geosci. Model Dev., 19, 4071–4093, `https://gmd.copernicus.org/articles/19/4071/2026/`.
- Shifts WRF geopotential heights (`(PH + PHB)/g`) relative to local WRF terrain (`HGT`) onto PALM height above ground (`z_agl`), clamps scalar and wind profiles smoothly below the lowest WRF half-level, and hydrostatically reduces surface pressure to `origin_z`.

### C. 3-Mode Chemistry & 7-Species Absolute WRF–SALSA Coupling (`CHEM_OPT = 100`)
- **Strict Mechanism Validation**: Inspects the `CHEM_OPT` global attribute in every `wrfout_*` file against `chemistry.wrf_chem_opt` (`100`: `RACM_KPP_MADE_SORGAM_GOCART`), raising a `ValueError` on mismatch.
- **YAML-Selectable Simulation Modes (`chemistry.palm_mode`)**:
  1. **`phstatp-salsa` (default, `115` fields, `absolute_mass_number_v1` schema)**:
     - **Meteorology + PHSTATP**: LOD2 `u`, `v`, `w`, `pt`, `qv`, `surface_forcing_surface_pressure`, plus `no`, `no2`, `o3` (`ppmv` $\rightarrow$ `ppm`) and `PM10` ($\mu\text{g/m}^3 \rightarrow \text{kg/m}^3$, set `bc_cs_t = 'dirichlet'`).
     - **Conservative 7-Species × 10-Bin WRF–SALSA Remapping (`salsa_remap.py`)**: Maps 41 WRF MADE/SORGAM+GOCART mass fields and 3 modal numbers (`nu0`, `ac0`, `corn`) onto 10 sectional SALSA bins (`3–50 nm`, `50 nm–10 µm`) and **7 dry components (`SO4, OC, BC, DU, SS, NO, NH`)** in `kg/m³` and `#/m³`.
     - **`antha` Exclusion & Audit Budgets**: Excludes unspeciated coarse anthropogenic `antha` (`antha_policy: exclude`), writes `*_unresolved_aerosol_mass` diagnostics, and floors the 5 SALSA precursor gases (`H2SO4`, `HNO3`, `NH3`, `OCNV`, `OCSV`) at `1.0 #/m³` when `nlcnd = .FALSE.`, `nsnucl = 0`.
  2. **`phstatp` (`55` fields)**: Strips `&salsa_parameters` and `salsa_*` outputs for gas-phase chemistry + passive `PM10` only.
  3. **`meteorology` (`31` fields)**: Strips both `&chemistry_parameters` and `&salsa_parameters` for pure 3D urban flow/thermodynamics.
  *(Legacy `legacy_3spec` (`97` fields, `mass_fracs_a` `['OC', 'DU', 'SS']`) remains supported for archival comparisons.)*

---

## 3. Operational Execution, 1-Minute Cadence & Output Processing

Implemented in `src/oper_forecast/preprocessing/palm/palm_setup.py` and wired into `src/oper_forecast/cli.py` (`model: "palm"`). Supports comma-separated chained tiers via `PALM_MODEL_CONFIGS` / `--palm-configs` (e.g. `100 m` SLUrb followed by `10 m` USM/PCM).

### A. CLI Commands
```bash
# 1. Generate PALM dynamic driver from WRF-Chem wrfout (auto-selects d02 -> d01 fallback)
PYTHONPATH=src "${PYTHON_BIN}" -m oper_forecast.cli prep-icbc \
    --config "${PALM_CONFIG}" \
    --date "${START_DATE}"

# 2. Scaffold PALM cycle workspace (INPUT/, MONITORING/, run/, OUTPUT/), render PARIN (1-min output), generate runPalm.sh
PYTHONPATH=src "${PYTHON_BIN}" -m oper_forecast.cli setup-workspace \
    --config "${PALM_CONFIG}" \
    --date "${START_DATE}"

# 3. Execute PALM-4U MPI simulation and combine_plot_fields.x
bash "${PALM_WORK_DIR}/${RUN_NAME}/${CYCLE_ID}/run/runPalm.sh"
```

### B. Workspace Layout, File Activation Table & Graceful Mid-Run Stop
Inside `${PALM_WORK_DIR}/${RUN_NAME}/${CYCLE_ID}/`:
- `INPUT/${CASE_NAME}_p3d` — Rendered namelist (`origin_date_time`, `end_time`, `npex`, `npey`, `dt_data_output = 60.0 s`, mode-filtered `&chemistry_parameters` / `&salsa_parameters`).
- `INPUT/${CASE_NAME}_static` — Symlink to `${PALM_STATIC_FILE}` (and `_slurb` -> `${PALM_SLURB_FILE}` for `100 m` SLUrb).
- `INPUT/${CASE_NAME}_dynamic` — Generated PIDS dynamic driver (`24h` operational window).
- `run/` — Execution directory where `runPalm.sh` removes stale `DO_STOP_NOW` / `DO_RESTART_NOW` / `PLOT*` files and links:
  - `PARIN -> ../INPUT/${CASE_NAME}_p3d`
  - `PIDS_STATIC -> ../INPUT/${CASE_NAME}_static`
  - `PIDS_SLURB -> ../INPUT/${CASE_NAME}_slurb` *(when configured)*
  - `PIDS_DYNAMIC -> ../INPUT/${CASE_NAME}_dynamic`
  - `RRTMG_LW -> ${PALM_ROOT}/packages/palm/model/lib/rrtmg/share/data/rrtmg_lw.nc`
  - `RRTMG_SW -> ${PALM_ROOT}/packages/palm/model/lib/rrtmg/share/data/rrtmg_sw.nc`
  - `palm -> ${PALM_BUILD_DIR}/palm`
  - `combine_plot_fields.x -> ${PALM_BUILD_DIR}/combine_plot_fields.x`
- `OUTPUT/` — Final combined 1-minute NetCDF outputs (`DATA_1D_PR_NETCDF`, `DATA_2D_XY_NETCDF`, `DATA_MASK_NETCDF_M001`, `DATA_3D_NETCDF`).
- **Graceful Early Termination (`DO_STOP_NOW`)**: Creating `touch "${PALM_WORK_DIR}/${RUN_NAME}/${CYCLE_ID}/run/DO_STOP_NOW"` triggers PALM's native end-of-timestep exit (`PAC0004`), cleanly flushing open NetCDFs so `combine_plot_fields.x` and downstream portal export preserve all completed 1-minute steps without corruption.

### C. Known Gotchas, Multigrid Decomposition & Troubleshooting
1. **Optimal MPI Decomposition for Multigrid Pressure Solver**:
   - PALM's geometric multigrid solver (`psolver = 'multigrid'`) halves the local subdomain dimensions `(nx+1)/npex`, `(ny+1)/npey`, `nz` at each coarsening level:
     - **`100 m` SLUrb (`192 × 192 × 32`)**: `npex = 6, npey = 4` (`24` physical ranks) gives `32 × 48 × 32` subdomains.
     - **`10 m` USM/PCM (`200 × 200 × 48`)**: **`npex = 5, npey = 5` (`25` physical ranks)** pinned to physical cores (`I_MPI_PIN=1`, `I_MPI_PIN_DOMAIN=core`) yields $40 \times 40 \times 48$ subdomains divisible by $2^3 = 8$, keeping all 4 multigrid levels distributed (`mg_gather = 0`, 6.1× faster `poismg`, 1.75× faster total runtime, ~350 MiB RSS/rank).
2. **Intel oneAPI `vars.sh` Unbound Variable (`OCL_ICD_FILENAMES`)**:
   - Never place `set -u` (`set -euo pipefail`) *before* `source "${ENV_SCRIPT}" && ${MODULE_ENV_CMD}` in `runPalm.sh`; always enable `set -euo pipefail` *after* environment activation.
3. **Intel Fortran `-fpe0` False Positive Traps in Vectorized Loops**:
   - Avoid `-fpe0` in `%compiler_options` when compiling PALM-4U with `mpiifx` (`QNaN` in SIMD lanes raises `forrtl: error (65): floating invalid`). Use `-O2 -fp-model source -fno-alias -ftz -nbs`.
4. **Post-Run `combine_plot_fields.x` & `PLOT2D_XY_*` Hygiene**:
   - Always run `./combine_plot_fields.x` immediately after `mpirun ./palm` finishes and purge leftover per-rank binary chunks (`PLOT2D_XY_*`, `PLOT3D_DATA_*`) once `DATA_*_NETCDF` files are archived in `OUTPUT/`.
