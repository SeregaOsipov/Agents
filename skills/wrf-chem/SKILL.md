---
name: wrf-chem
description: >-
  Use this skill when configuring, compiling, executing, or debugging the WRF-Chem (Weather Research and Forecasting model with Chemistry) atmospheric modeling system on HPC or cloud clusters (e.g. AWS ParallelCluster, Slurm). Covers Intel oneAPI compilation, namelist.input configuration, chemical/aerosol IC/BC injection via Merra2BC (cams2wrf), auxiliary inputs (HERMESv3 emissions, SST updates, FDDA), and multi-node MPI execution. All paths are parameterized; ask the user for any missing paths.
---

# WRF-Chem Model Execution & Operational Forecasting

This skill serves as the primary operational runbook for configuring, compiling, and running WRF-Chem simulations on HPC and cloud clusters.

> **CRITICAL AGENT INSTRUCTION (Path Parameterization & Interactive Disambiguation):**
> All paths in this runbook are parameterized and platform-independent. **Do NOT assume hardcoded user paths or cluster mounts** (such as `/home/username` or specific `/shared/scratch` mounts).
> 
> **Before executing or generating scripts for any step**, verify that the necessary paths are defined in the active configuration, environment variables, or user context.
> **If any path is missing, not defined, or ambiguous, YOU MUST PROMPT AND ASK THE USER for the path rather than making assumptions.**

---

## Environment Variables & Path Glossary

| Variable | Description | Typical / Example Location |
| :--- | :--- | :--- |
| `$WRF_DIR` | WRF source and build root directory | `${HOME}/Models/WRF` |
| `$WRF_WORK_DIR` | Working scratch directory for WRF-Chem execution | `${SCRATCH}/simulations/WRF_run/operational_forecast` |
| `$TEMPLATE_DIR` | Baseline functional WRF run directory (tables, namelist) | `${SCRATCH}/simulations/WRF_run/run_ag_2026` |
| `$MERRA2BC_DIR` | Path to Merra2BC repository (cams2wrf / merra2wrf) | `${HOME}/workspace/Merra2BC` |
| `$EMISSIONS_FILE` | Anthropogenic chemistry emissions file | `${DATA_ROOT}/emissions/HERMESv3_...nc` |
| `$LOWINP_FILE` | Lower boundary conditions file (SST, sea-ice updates) | `${DATA_ROOT}/IC_BC/wrflowinp_d02` |
| `$FDDA_FILE` | Analysis nudging file (optional) | `${DATA_ROOT}/IC_BC/wrffdda_d02` |
| `$ENV_SCRIPT` | HPC environment / module loader script | `${HOME}/.commonrc` or `/etc/profile.d/modules.sh` |
| `$MODULE_ENV_CMD`| Environment initialization command or alias | `gogowrfchem` |

---

## 1. Compilation on HPC / AWS

### Prerequisites
WRF requires the compiler toolchain, NetCDF C/Fortran, Parallel NetCDF, JasPer, Flex, and YACC:
```bash
source "${ENV_SCRIPT}"
${MODULE_ENV_CMD}
```
Key environment variables exported by `${MODULE_ENV_CMD}`:
- `WRF_CHEM=1` and `WRF_KPP=1`
- `NETCDF`: Fortran NetCDF prefix (`nf-config --prefix`)
- `PNETCDF`: Parallel NetCDF prefix
- `JASPERLIB` & `JASPERINC`: JasPer library for GRIB2 compression
- `FLEX_LIB_DIR` & `YACC`: Required for KPP chemical mechanism parsing

### Compilation Steps
*Prompt the user for `$WRF_DIR` if not defined in configuration or context.*

```bash
cd "${WRF_DIR}"

# 1. Activate environment
source "${ENV_SCRIPT}"
${MODULE_ENV_CMD}

# 2. Link platform-tested configuration (e.g. configure.wrf.aws)
ln -sf configure.wrf.aws configure.wrf

# 3. Compile em_real (typically submitted via batch script)
./compile em_real >& log.compile_wrf_me
```

**Produced Executables** (in `${WRF_DIR}/main/`):
- `wrf.exe`: Main WRF-Chem integration binary
- `real.exe`: Vertical interpolation and IC/BC generator
- `ndown.exe`: One-way nesting downscaling tool
- `tc.exe`: Tropical cyclone initialization tool

---

## 2. Model Execution Workflow

### A. Operational Workspace Scaffolding
*Prompt the user for `$WRF_WORK_DIR` and `$TEMPLATE_DIR` if not defined.*

Target run directory: `${WRF_WORK_DIR}/${RUN_NAME}/`

1. Create directory structure: `run/`, `data/`, `output/`, `logs/`, `config/`.
2. Symlink all static physics lookup tables (`*.TBL`, `*.bin`, `*.dat`, `*.asc`, `constants.asc`) from `${TEMPLATE_DIR}/`.
3. Symlink binaries: `wrf.exe`, `real.exe`, `ndown.exe` from `${TEMPLATE_DIR}/` (or `${WRF_DIR}/main/`).
4. Symlink auxiliary boundary files:
   - `wrfchemi_d01 -> ${EMISSIONS_FILE}`
   - `wrflowinp_d01 -> ${LOWINP_FILE}`
   - `wrffdda_d01 -> ${FDDA_FILE}`

### B. Meteorological Initialization (`real.exe`)

> **CRITICAL RULE (No Heavy Compute on Login Nodes):**
> `real.exe` processes the full 3D meteorological grid across all vertical levels and time slices. Always run it via Slurm batch submission (`sbatch runReal.sh`) on compute nodes, never interactively on the login node.

1. Link analysis `met_em.d01.*.nc` files from WPS into the `run/` directory.
   *(If `nocolons = .true.` is enabled in `namelist.input`, link both colon and underscore variants, e.g. `met_em.d01.YYYY-MM-DD_HH_00_00.nc`).*
2. Configure `namelist.input` matching WPS levels:
   - For CAMS 137 model levels: `num_metgrid_levels = 138` (137 upper-air + 1 surface level).
   - For ECMWF 4-layer soil: `num_metgrid_soil_levels = 4`.
   - **Crucial Namelist Setting for `real.exe`:** Set `chem_opt = 100` and `chem_in_opt = 0` so `real.exe` allocates all chemistry arrays in `wrfinput_d01` and `wrfbdy_d01` without attempting to read external `wrf_chem_input_d01`.
3. Reference Slurm Script (`runReal.sh`):
   ```bash
   #!/bin/bash -l
   #SBATCH --job-name=WRF.real
   #SBATCH --partition=hpc-mpi
   #SBATCH --output=output_real.txt
   #SBATCH --error=error_real.txt
   #SBATCH --nodes=1
   #SBATCH --ntasks-per-node=16
   #SBATCH --time=00:30:00
   #SBATCH --hint=nomultithread

   export MODULES_PAGER=""
   export PAGER="cat"
   if [ -f "${HOME}/.commonrc" ]; then
       source "${HOME}/.commonrc"
   fi
   gogowrfchem
   ulimit -s unlimited

   mpirun -n 16 ./real.exe >& log.real
   echo "real.exe completed with status $?"
   ```
4. Verify `output_real.txt` or `rsl.error.0000` for `SUCCESS COMPLETE REAL_EM`.

### C. Chemical & Aerosol IC/BC Preparation (`Merra2BC`)
*Prompt the user for `$MERRA2BC_DIR` and `$CAMS_DIR` if not defined.*

WRF-Chem initial and boundary conditions are created by modifying baseline meteorological `wrfinput_d01` and `wrfbdy_d01` in-place using tools from `${MERRA2BC_DIR}`:

```bash
python -u "${MERRA2BC_DIR}/cams2wrf_main.py" \
    --start_date "${START_DATE}_00:00:00" \
    --end_date "${END_DATE}_00:00:00" \
    --hourly_interval "${HOURLY_INTERVAL}" \
    --do_IC --do_BC --zero_out_first \
    --reanalysis_dir "${CAMS_DIR}/" \
    --reanalysis_file_name_template "ECMWF-CAMS_{stream}_{date_time}.nc" \
    --wrf_dir "${TARGET_RUN_DIR}" \
    --wrf_input wrfinput_d01 \
    --wrf_bdy_file wrfbdy_d01 \
    --wrf_met_dir "${MET_EM_DIR}" \
    --wrf_met_files "met_em.d01.*" \
    --wrf_met_files_date_format "%Y-%m-%d_%H:%M:%S"
```
*(For NASA MERRA-2, use `merra2wrf_main.py` with analogous arguments).*

> **Important Notes:**
> 1. `cams2wrf_main.py` modifies `wrfinput` and `wrfbdy` **in place (`r+` mode)**.
> 2. **Photolysis Tables:** If using TUV photolysis (`phot_opt = 4`), ensure `DATAE1` and `DATAJ1` directories are populated from `${HOME}/Data/AirQuality/AQABA/DATAE1` (containing `1995Malicet_O3.txt`, `wmo85`, etc.).
> 3. **Emissions Time Stamping:** When `io_style_emissions = 2`, WRF looks for `wrfchemi_d01_<date>`. The NetCDF `Times` variable in the emissions file must match the forecast cycle start date (`YYYY-MM-DD_00:00:00`).
> 4. **Post-Injection Namelist Switch:** Immediately after IC/BC injection completes, update `chem_in_opt = 1, 1,` in `namelist.input` so `wrf.exe` reads the injected chemistry from `wrfinput_d01`.

### D. Namelist (`namelist.input`) Configuration
Key namelist switches for operational chemistry forecasts:
```fortran
&time_control
 run_days = ${RUN_DAYS},
 run_hours = ${RUN_HOURS},
 start_year = ${START_YEAR}, start_month = ${START_MONTH}, start_day = ${START_DAY}, start_hour = ${START_HOUR},
 end_year   = ${END_YEAR},   end_month   = ${END_MONTH},   end_day   = ${END_DAY},   end_hour   = ${END_HOUR},
 interval_seconds = ${INTERVAL_SECONDS}, ! e.g. 10800 for 3-hourly boundary updates
 history_interval = ${HISTORY_INTERVAL}, ! e.g. 60 for 1-hourly output
 io_form_history  = 11,                  ! Parallel NetCDF (pnetcdf)
 io_form_input    = 2,                   ! Standard NetCDF
 io_form_boundary = 2,
 force_use_old_data = .true.,
 nocolons         = .true.,
/

&domains
 max_dom = ${MAX_DOM},
 e_we = ${E_WE},
 e_sn = ${E_SN},
 e_vert = ${E_VERT},
 dx = ${DX}, dy = ${DY},
 time_step = ${TIME_STEP},
/

&chem
 chem_opt = ${CHEM_OPT},                 ! e.g. 100 for RADM2/MADE-SORGAM
 chem_in_opt = 1,                        ! Initialize chemistry from wrfinput (MUST be 1 for wrf.exe)
 gas_ic_opt = 1, gas_bc_opt = 1,         ! Ingest gas IC & BC from wrfinput/wrfbdy
 aer_ic_opt = 1, aer_bc_opt = 1,         ! Ingest aerosol IC & BC from wrfinput/wrfbdy
 have_bcs_chem = .true.,                 ! Read chemistry boundary conditions from wrfbdy
 io_style_emissions = 2,                 ! Date/time specific emissions
 phot_opt = 4,                           ! TUV photolysis
/
```

### E. Submitting the Execution Job (`runWrf.sh`)

> **CRITICAL RULE (All Model Integrations Must Run via Slurm):**
> Compute-heavy WRF-Chem simulations require extensive memory and parallel CPUs (~2-3 GB RAM per MPI rank across 50 vertical levels and ~100 chemistry species). **Never run `wrf.exe` on the head/login node** (it will be terminated with Signal 9 OOM-killer). Always submit `runWrf.sh` via Slurm `sbatch`.

Reference script based on template `${TEMPLATE_DIR}/runWrf.sh`:
```bash
#!/bin/bash -l
#SBATCH --job-name=WRF.${RUN_NAME}
#SBATCH --partition=hpc-mpi
#SBATCH --output=output.txt
#SBATCH --error=error.txt
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=32
#SBATCH --ntasks-per-core=1
#SBATCH --time=02:00:00
#SBATCH --hint=nomultithread

# Load environment modules without interactive pager
export MODULES_PAGER=""
export PAGER="cat"
if [ -f "${HOME}/.commonrc" ]; then
    source "${HOME}/.commonrc"
fi
gogowrfchem
ulimit -s unlimited

# Intel MPI diagnostics & unbuffered log output
export I_MPI_DEBUG=5
export FI_LOG_LEVEL=info
export WRF_LOG_BUFFERING=0

# Launch MPI integration across allocated compute tasks
mpirun -n 32 ./wrf.exe

echo "Done"
```

Submit to Slurm:
```bash
sbatch runWrf.sh
```

---

## 3. Post-Processing & Diagnostics

### A. Output Verification
- Monitor `output.txt` and `rsl.error.0000` for `wrf: SUCCESS COMPLETE WRF`.
- Verify generated history files: `wrfout_d01_YYYY-MM-DD_HH_MM_SS` (or colon format).
- Check chemical fields (`o3`, `co`, `no2`, `so2`, `so4aj`, `soila`, `seas`, `PM2_5_DRY`, `PM10`) with `ncdump -h` or Python `netCDF4`.

### B. Cluster & AWS Troubleshooting Runbook
1. **Login Node Memory Kill (Signal 9 / Killed):**
   - Head/login nodes typically have 30 GB total RAM and no swap. Running multiple WRF-Chem MPI ranks locally triggers the Linux kernel OOM killer. Always submit jobs to Slurm compute nodes using `sbatch`.
2. **Slurm Accounting Limits (`AssocGrpSubmitJobsLimit`):**
   - If `sbatch` fails with `AssocGrpSubmitJobsLimit`:
     ```bash
     sacctmgr show assoc where account=${ACCOUNT} format=Account,User,GrpSubmit,GrpJobs
     ```
   - If `GrpSubmit = 0`, job submissions are prohibited for this account by cluster administration.
3. **AWS ParallelCluster `PROTECTED` Mode & Credit Exhaustion:**
   - Check `/var/log/parallelcluster/clustermgtd`:
     If logs report: `Current compute fleet status: PROTECTED` and `Partitions bootstrap failure count reaches threshold 10`, the AWS compute fleet was automatically paused because compute EC2 instances failed to launch.
   - Common causes:
     - **AWS Credit Exhaustion / Account Suspension:** AWS refuses EC2 `RunInstances` API calls.
     - **EC2 Capacity Limits (`InsufficientInstanceCapacity`):** Specified instance type (e.g. `c6i.32xlarge`) is unavailable in the subnet's AZ (e.g. `us-east-1a`).
     - **vCPU Quota Limits (`VcpuLimitExceeded`):** Account has hit EC2 On-Demand vCPU service limits.
   - Once AWS credits, quotas, or capacity are restored by administrators, reactivate the fleet:
     ```bash
     pcluster update-compute-fleet --cluster-name ${CLUSTER_NAME} --status START_REQUESTED
     ```

---

## 6. Multi-Platform & Multi-Cloud Portability

The operational WRF-Chem pipeline is completely decoupled from specific cloud infrastructure:

### A. Architecture
- **Model Configs (`config/models/`)**: Define simulation science, domain dimensions, physics, and input datasets.
- **Cluster Profiles (`config/clusters/`)**: Define physical infrastructure (scratch mounts, Slurm partitions, hardware core topologies, environment module activations, and MPI runtime flags).

### B. Supported Platform Profiles
- **AWS ParallelCluster (`aws_pcluster.yaml`)**:
  - Partition: `hpc-mpi`, 32 tasks per node (c6i instances)
  - MPI / Fabric: Intel MPI with AWS Elastic Fabric Adapter (`I_MPI_DEBUG=5`, `FI_LOG_LEVEL=info`)
  - Sourcing: `${HOME}/.commonrc` and `gogowrfchem`
- **Azure CycleCloud (`azure_cyclecloud.yaml`)**:
  - Partition: `hb120-hpc`, 60 tasks per node (Standard_HB120rs_v3 AMD Milan)
  - MPI / Fabric: Mellanox InfiniBand HDR/NDR via UCX (`UCX_NET_DEVICES=mlx5_ib0:1`, `UCX_TLS=rc,sm`)
  - Sourcing: Standard Environment Modules (`/etc/profile.d/modules.sh`, `module load wrf/4.5.1 ...`)
- **Generic Cluster Template (`cluster_template.yaml`)**:
  - Documented boilerplate for rapid onboarding of any on-premise or cloud HPC cluster.

### C. Execution via CLI
Switching target clusters requires only changing the `--cluster` flag:
```bash
# Target AWS:
python -m oper_forecast.cli setup-workspace --config config/models/wrfchem_cams.yaml --cluster aws_pcluster
python -m oper_forecast.cli start-cycle     --config config/models/wrfchem_cams.yaml --cluster aws_pcluster --date 2026-10-03

# Target Azure:
python -m oper_forecast.cli setup-workspace --config config/models/wrfchem_cams.yaml --cluster azure_cyclecloud
python -m oper_forecast.cli start-cycle     --config config/models/wrfchem_cams.yaml --cluster azure_cyclecloud --date 2026-10-03
```
