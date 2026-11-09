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
| `$PALM_WORK_DIR` | Working scratch directory for PALM-4U operational cycles | `/scratch/sims/PALM_run/operational_forecast` |
| `$PALM_STATIC_FILE` | PIDS-compliant PALM static driver (`_static` NetCDF with topography, buildings, pavement, vegetation, soil, street types) | `/scratch/sims/PALM_run/static/DohaForecastChem_static` |
| `$WRF_OUTPUT_DIR` | Directory containing hourly parent `wrfout_d01_YYYY-MM-DD_HH_00_00` files | `/scratch/sims/WRF_run/operational_forecast/ag_forecast_cycle_weekly/run` |
| `$NETCDF_FORTRAN_ROOT` | Intel-compiled NetCDF C/Fortran installation prefix | `${HOME}/WRF_LIBS/intel` |
| `$ENV_SCRIPT` | HPC environment / module loader script | `${HOME}/.commonrc` |
| `$MODULE_ENV_CMD` | Environment initialization command or alias | `gogowrfchem` |

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
2. **SALSA Aerosol-Chemistry Coupling Patches (`config/palm/patches/salsa/`)**:
   - Apply the 4 SALSA stability and offline-nesting patches to `${PALM_ROOT}/packages/palm/model/src/`:
     - `salsa_mod.f90`: Bounds aerosol bin number/mass concentrations and safely couples SALSA offline boundary reading (`salsa_nesting_offl_bc`, `salsa_nesting_offl_init`) without diagnostic `WRITE(*,*)` stdout spam.
     - `netcdf_data_input_mod.f90`: Supports dynamic driver input for SALSA variables.
     - `timestep.f90` & `time_integration.f90`: Safely handles SALSA sub-stepping and boundary updates during Runge-Kutta integration.
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

Implemented in `src/oper_forecast/preprocessing/palm/wrf_to_palm_dynamic.py` and configured in `config/models/palm_doha_chem.yaml`.

### A. Grid & Coordinate Mapping
- Reads grid geometry (`origin_x`, `origin_y`, `origin_z`, `origin_lat`, `origin_lon`, `rotation_angle`, `crs`) directly from the PALM static driver (`${PALM_STATIC_FILE}`) and domain parameters (`nx`, `ny`, `nz`, `dx`, `dy`, `dz`, `dz_stretch_level`, `dz_stretch_factor`, `dz_max`) from `config/models/palm_doha_chem.yaml`.
- Projects PALM staggered (`xu`, `yv`, `zw`) and cell-center (`x`, `y`, `z`) coordinates onto the WRF Lambert Conformal Conic (LCC) grid, performing bilinear horizontal interpolation and vector wind rotation (`u`, `v`) from WRF grid coordinates to PALM local coordinates.

### B. Near-Ground Vertical Adaptation (`PALM-meteo` GMD 2026 Methodology)
- Reference: Krč et al. (2026), *PALM-meteo 2.8: Processor of PALM meteorological input data*, Geosci. Model Dev., 19, 4071–4093, `https://gmd.copernicus.org/articles/19/4071/2026/`.
- Because mesoscale WRF terrain (`HGT`, ~12.7 m MSL over Doha) differs from high-resolution PALM microscale topography (`origin_z = 5.0 m` MSL) and the lowest WRF mass level center sits at ~25.6 m AGL (above PALM's lowest 8 vertical levels `z = 1.5..22.5 m` AGL):
  - **Terrain-Relative / Barometric Vertical Adaptation**: Shifts WRF geopotential heights (`(PH + PHB)/g`) relative to local WRF terrain (`HGT`) so surface-layer features align with PALM height above ground (`z_agl`).
  - **Lowest-Level Clamping Below $z_{\text{WRF}}[0]$**: Below the lowest WRF half-level (~25.6 m AGL), PALM-meteo pads/clamps scalar and wind profiles (`np.interp` / `lpad` in `palmmeteo/vinterp.py`), while surface pressure is hydrostatically reduced to `origin_z` via the barometric equation.

### C. Mechanism-Specific Chemistry & SALSA Aerosol Mapping (`CHEM_OPT = 100`)
- **Strict Mechanism Validation**:
  - `wrf_to_palm_dynamic.py` inspects the `CHEM_OPT` global attribute in every `wrfout_d01_*` file and verifies it against `chemistry.wrf_chem_opt` (`100`: RACM KPP gas-phase + MADE/SORGAM 3-mode lognormal aerosols + GOCART dust/sea-salt). If `CHEM_OPT` does not match, it raises a `ValueError` rather than applying an invalid variable mapping.
- **Gas-Phase (`phstatp` mechanism)**:
  - Maps WRF-Chem `no`, `no2`, `o3` (`ppmv` $\rightarrow$ `ppm`, scale `1.0`) and `PM10` ($\mu\text{g/m}^3 \rightarrow \text{kg/m}^3$, scale `1e-9`) via `chemistry.gas_mapping` in YAML to `init_atmosphere_<SPC>` (LOD 1) and `ls_forcing_{left,right,south,north,top}_<SPC>` (LOD 2).
- **SALSA Aerosol Module (10 Sectional Bins `nbin = [3, 7]`, 3 Active Mass Components `['OC', 'DU', 'SS']`)**:
  - **Aerosol Policy (Future Work)**: WRF-Chem modal-to-sectional aerosol remapping is physically uncalibrated and postponed for future research. In operational forecasts (`skip_aerosol_mapping: true`), aerosol boundary conditions in `PIDS_DYNAMIC` are initialized to a clean numerical background floor (`1.0 #/m³`) and neutral mass fractions (`[0.3333, 0.3333, 0.3334]`), while gas chemistry (`NO`, `NO2`, `O3`, `PM10`) remains fully coupled.
  - When remapping is enabled: Converts WRF-Chem MADE/SORGAM modal number concentrations (`nu0`, `ac0`, `corn`) to `#/m³` via $\rho_{\text{dry}}$ and projects onto 10 SALSA bins via lognormal quadrature (`compute_salsa_bin_weights`), with mass fractions from `soila` (`DU`), `seas` (`SS`), and organic/inorganic mass (`OC`).
  - Sets the 5 SALSA precursor gases (`H2SO4`, `HNO3`, `NH3`, `OCNV`, `OCSV`) to a uniform safety floor (`salsa_gas_floor_m3: 1.0 #/m³`) when condensation/nucleation are disabled (`nlcnd = .FALSE.`, `nsnucl = 0`) to prevent dry-deposition division-by-zero.

---

## 3. Operational Execution & Output Processing

Implemented in `src/oper_forecast/preprocessing/palm/palm_setup.py` and wired into `src/oper_forecast/cli.py` (`model: "palm"`).

### A. CLI Commands
```bash
# 1. Generate PALM dynamic driver from WRF-Chem hourly wrfout files
PYTHONPATH=src /home/osipovs/apps/miniforge3/envs/py312/bin/python -m oper_forecast.cli prep-icbc \
    --config config/models/palm_doha_chem.yaml \
    --date 2026-11-05

# 2. Scaffold PALM cycle workspace (INPUT/, run/, OUTPUT/), render PARIN, and generate runPalm.sh
PYTHONPATH=src /home/osipovs/apps/miniforge3/envs/py312/bin/python -m oper_forecast.cli setup-workspace \
    --config config/models/palm_doha_chem.yaml \
    --date 2026-11-05

# 3. Execute PALM-4U MPI simulation and combine_plot_fields.x
bash /scratch/sims/PALM_run/operational_forecast/doha_forecast_chem/20261105_00/run/runPalm.sh
```

### B. Workspace Layout & File Activation Table
Inside `${PALM_WORK_DIR}/${RUN_NAME}/${CYCLE_ID}/`:
- `INPUT/${RUN_ID}_p3d` — Rendered namelist (`origin_date_time`, `end_time`, `npex`, `npey`).
- `INPUT/${RUN_ID}_static` — Symlink to `${PALM_STATIC_FILE}`.
- `INPUT/${RUN_ID}_dynamic` — Generated PIDS dynamic driver (`24h` / `25` hourly steps).
- `run/` — Execution directory where `runPalm.sh` links:
  - `PARIN -> ../INPUT/${RUN_ID}_p3d`
  - `PIDS_STATIC -> ../INPUT/${RUN_ID}_static`
  - `PIDS_DYNAMIC -> ../INPUT/${RUN_ID}_dynamic`
  - `RRTMG_LW -> ${PALM_ROOT}/packages/palm/model/rrtmg_src/rrtmg_lw.nc`
  - `RRTMG_SW -> ${PALM_ROOT}/packages/palm/model/rrtmg_src/rrtmg_sw.nc`
  - `palm -> ${PALM_BUILD_DIR}/palm`
  - `combine_plot_fields.x -> ${PALM_BUILD_DIR}/combine_plot_fields.x`
- `OUTPUT/` — Final combined NetCDF outputs (`DATA_1D_PR_NETCDF`, `DATA_2D_XY_NETCDF`, `DATA_2D_XY_AV_NETCDF`, `DATA_3D_NETCDF`, `RUN_CONTROL`, `HEADER`).

### C. Known Gotchas, Multigrid Decomposition & Troubleshooting
1. **Optimal MPI Decomposition for Multigrid Pressure Solver (`npex = 5, npey = 5` on a $200 \times 200 \times 48$ Grid)**:
   - PALM's geometric multigrid solver (`psolver = 'multigrid'`) halves the local subdomain dimensions `(nx+1)/npex`, `(ny+1)/npey`, `nz` at each coarsening level.
   - For a $200 \times 200 \times 48$ grid on a 28-physical-core workstation, **`npex = 5, npey = 5` (`25` MPI ranks)** pinned to physical cores (`I_MPI_PIN=1`, `I_MPI_PIN_DOMAIN=core`) yields a $40 \times 40 \times 48$ subdomain per rank, which is divisible by $2^3 = 8$ (`40 → 20 → 10 → 5` and `48 → 24 → 12 → 6`), keeping all 4 multigrid levels distributed across all 25 PEs without gathering onto `PE0`. This speeds up `poismg` by **6.1×** and total runtime by **1.75×** compared to `16` ranks (`4 × 4`, $50 \times 50 \times 48$), while using only **~350 MiB RSS per rank** (~8.75 GiB total RAM).
2. **Intel oneAPI `vars.sh` Unbound Variable (`OCL_ICD_FILENAMES`)**:
   - Never place `set -u` (`set -euo pipefail`) *before* `source ~/.commonrc && gogowrfchem` in `runPalm.sh`; Intel's OpenCL ICD hook references `OCL_ICD_FILENAMES` without a default and will abort under `set -u`. Always enable `set -euo pipefail` *after* environment activation.
2. **Intel Fortran `-fpe0` False Positive Traps in Vectorized Loops**:
   - Avoid `-fpe0` in `%compiler_options` when compiling PALM-4U with `mpiifx -O3`. Intel `ifx` vectorizes `MINVAL`/`MAXVAL` (`minsd`/`maxsd`) in `advec_s_ws` and chemistry routines across padded SIMD lanes or unmasked building cells; under `-fpe0`, any `QNaN` in an unused lane or uninitialized compensation-point entry raises `forrtl: error (65): floating invalid`. Use `-O3 -fp-model source -fno-alias -ftz -no-prec-div -nbs`.
3. **Post-Run `combine_plot_fields.x`**:
   - In MPI runs without parallel NetCDF4 I/O, each rank writes temporary per-PE binary files (`PLOT2D_XY_000000`, `PLOT3D_DATA_000000`, etc.) and rank 0 writes the NetCDF skeleton (`DATA_2D_XY_NETCDF`, `DATA_3D_NETCDF`). Always run `./combine_plot_fields.x` in `run/` immediately after `mpirun ./palm` finishes (and clean stale `PLOT*` / `DATA_*` files before starting a new run).
