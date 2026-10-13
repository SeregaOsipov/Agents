---
name: wps
description: >-
  Use this skill when configuring, compiling, or executing the WRF Preprocessing System (WPS) on HPC or cloud clusters (e.g. AWS ParallelCluster, SLURM environments). Covers the strict dependency requirement where WRF must always be compiled first, linking platform-specific configuration files (e.g. configure.wps.aws), running ungrib and metgrid, and preparing meteorological intermediate fields (met_em) for WRF simulations. All paths are parameterized; ask the user for any missing paths.
---

# WRF Preprocessing System (WPS) Execution & Compilation Runbook

This skill covers configuring, compiling, and running the WRF Preprocessing System (WPS) on HPC and cloud clusters.

> **CRITICAL AGENT INSTRUCTION (Path Parameterization & Interactive Disambiguation):**
> All paths in this runbook are parameterized and platform-independent. **Do NOT assume hardcoded user paths or cluster mounts** (such as `/home/username` or specific `/shared/scratch` mounts).
> 
> **Before executing or generating scripts for any step**, verify that the necessary paths are defined in the active configuration, environment variables, or user context.
> **If any path is missing, not defined, or ambiguous, YOU MUST PROMPT AND ASK THE USER for the path rather than making assumptions.**

---

## Environment Variables & Path Glossary

| Variable | Description | Typical / Example Location |
| :--- | :--- | :--- |
| `$WPS_DIR` | WPS source and build root directory | `${HOME}/Models/WPS` |
| `$WRF_DIR` | Compiled WRF model directory | `${HOME}/Models/WRF` |
| `$WPS_WORK_DIR` | Working scratch directory for WPS execution | `${SCRATCH}/simulations/WPS_run/oper_forecasting` |
| `$GEO_EM_DIR` | Directory containing pre-computed `geo_em` grid files | `${DATA_ROOT}/IC_BC/` |
| `$ENV_SCRIPT` | HPC environment / module loader script | `${HOME}/.commonrc` or `/etc/profile.d/modules.sh` |
| `$MODULE_ENV_CMD`| Environment initialization command or alias | `gogowrfchem` |

---

## 1. Compilation on HPC / AWS (Strict Prerequisites)

### Golden Rule: WRF Must Always Be Compiled First
WPS relies directly on the compiled WRF I/O libraries (such as `libwrfio_nf.a`) located inside the compiled WRF model directory (`$WRF_DIR`). **Never attempt to compile WPS without a previously compiled WRF installation.**

### Compilation Steps
*Prompt the user for `$WPS_DIR` and `$WRF_DIR` if they are not defined in configuration or context.*

1. **Activate Environment & Compiler Toolchain:**
   ```bash
   source "${ENV_SCRIPT}"
   ${MODULE_ENV_CMD}
   ```
   Ensure Intel/GNU compilers, NetCDF C/Fortran (`NETCDF`), Parallel NetCDF (`PNETCDF`), and JasPer (`JASPERLIB`, `JASPERINC`) are exported in the environment.

2. **Navigate and Set WRF Path:**
   ```bash
   cd "${WPS_DIR}"
   export WRF_DIR="${WRF_DIR}"
   ```

3. **Link Platform Configuration:**
   Do not run interactive `./configure`. Instead, link the platform-tested configuration (e.g., AWS Intel oneAPI):
   ```bash
   ln -sf configure.wps.aws configure.wps
   ```
   *(If on a different cluster, verify with the user which `configure.wps.*` stanza to use).*

4. **Compile All Utilities:**
   ```bash
   ./compile >& log.compile
   ```

5. **Verify Produced Binaries:**
   A successful build produces three primary symbolic links in `${WPS_DIR}`:
   - `geogrid.exe -> geogrid/src/geogrid.exe`
   - `ungrib.exe  -> ungrib/src/ungrib.exe`
   - `metgrid.exe -> metgrid/src/metgrid.exe`

---

## 2. Operational Execution Workflow

### A. Execution Workspace & Grid Inputs
*Prompt the user for `$WPS_WORK_DIR` and `$GEO_EM_DIR` if not defined.*

- **WPS Execution Scratch:** `${WPS_WORK_DIR}/${RUN_NAME}`
- **Domain Grid Files (`geo_em`):** Pre-generated domain grids are located in `${GEO_EM_DIR}` (e.g. `geo_em.d01.nc` or `geo_em.d02.nc`).
  *(When using pre-generated `geo_em` files, running `geogrid.exe` is bypassed; simply symlink the target grid as `geo_em.d01.nc` in the workspace).*

### B. Meteorological Intermediate Preprocessing
WPS requires meteorological fields converted into the WPS intermediate format (`FILE:*` or `FILE_unnc_*`):

#### Method 1: Python Direct NetCDF Unpack (for ECMWF CAMS / MERRA-2)
When driving WRF from NetCDF reanalysis or forecast streams, use direct intermediate converters:
```bash
# Operational CAMS 137 Hybrid Level Converter (cams_to_wps.py):
# Computes 3D midpoint pressures using GRIB_pv (a_k, b_k), maps surface geopotential z to SOILHGT,
# and integrates ECMWF OpenData 4-layer soil temperatures/moistures directly into FILE:YYYY-MM-DD_HH:
python -m oper_forecast.preprocessing.cams_to_wps \
    --sfc "${CAMS_SFC_FILE}" \
    --ml "${CAMS_ML_FILE}" \
    --soil "${OPENDATA_SOIL_FILE}" \
    --outdir "${WPS_WORK_DIR}" \
    --prefix FILE

# Alternative via ClimPy:
python -u "${CLIMPY_DIR}/climpy/wrf/WPS_netcdf_ungrib/wps_unnetcdf_ecmwf_OA.py" "${CAMS_SFC_FILE}"
python -u "${CLIMPY_DIR}/climpy/wrf/WPS_netcdf_ungrib/wps_unnetcdf_ecmwf_OA.py" "${CAMS_ML_FILE}"

# For NASA MERRA-2:
python -u "${CLIMPY_DIR}/climpy/wrf/WPS_netcdf_ungrib/wps_unnetcdf_merra2.py" \
    --start_date="${START_DATE}" --end_date="${END_DATE}" --out_storage_path="${STORAGE_PATH}"
```
These tools write the binary record structure directly via `wrf_write` or Python `struct.pack`, bypassing `ungrib.exe`.

#### Method 2: Standard Ungrib (for GRIB/GRIB2 files)
1. Link GRIB files using `link_grib.csh`:
   ```bash
   ./link_grib.csh "${GRIB_DIR}"/*.grib2
   ```
2. Link the appropriate variable table:
   ```bash
   ln -sf ungrib/Variable_Tables/Vtable.ECMWF Vtable
   ```
3. Execute `ungrib.exe`:
   ```bash
   ./ungrib.exe >& log.ungrib
   ```

### C. Running Metgrid (Always via Slurm Batch Job)

> **CRITICAL RULE (No Heavy Compute on Login Nodes):**
> `metgrid.exe` horizontally interpolates high-resolution 3D grids across numerous vertical levels (e.g. 137 CAMS model levels). This is memory- and CPU-intensive. **Never run `metgrid.exe` interactively on the cluster login/head node.** Always submit it to the Slurm scheduler using `sbatch`.

1. **Link Table:**
   ```bash
   ln -sf "${WPS_DIR}/metgrid/METGRID.TBL.ARW" METGRID.TBL
   ```
2. **Configure `namelist.wps`:**
   ```fortran
   &share
    wrf_core = 'ARW',
    max_dom = 1,
    start_date = '${START_DATE}_00:00:00',
    end_date   = '${END_DATE}_00:00:00',
    interval_seconds = ${INTERVAL_SECONDS}
   /

   &metgrid
    fg_name = 'FILE'
    io_form_metgrid = 2,
   /
   ```
3. **Reference Slurm Script (`runMetgrid.sh`):**
   ```bash
   #!/bin/bash -l
   #SBATCH --job-name=WPS.metgrid
   #SBATCH --partition=hpc-mpi
   #SBATCH --output=output_metgrid.txt
   #SBATCH --error=error_metgrid.txt
   #SBATCH --nodes=1
   #SBATCH --ntasks-per-node=16
   #SBATCH --ntasks-per-core=1
   #SBATCH --time=01:00:00
   #SBATCH --hint=nomultithread

   # Load environment
   export MODULES_PAGER=""
   export PAGER="cat"
   if [ -f "${HOME}/.commonrc" ]; then
       source "${HOME}/.commonrc"
   fi
   gogowrfchem
   ulimit -s unlimited

   # Execute metgrid via MPI
   mpirun -n 16 ./metgrid.exe >& log.metgrid

   echo "Metgrid completed with status $?"
   ```

4. **Submit to Slurm:**
   ```bash
   sbatch runMetgrid.sh
   ```

5. **Verification:**
   Ensure `met_em.d01.${DATE}_${HOUR}:00:00.nc` files are generated. These serve as input for WRF's `real.exe`.

---

## 3. Common Diagnostics & Troubleshooting
1. **Compute-Heavy Jobs on Login Nodes:** If processes are killed with Signal 9 (`Killed`), the Linux OOM-killer terminated them because login nodes have strict memory limits. Always submit compute jobs to Slurm compute nodes.
2. **AWS ParallelCluster Protected Mode & Slurm Accounting:**
   - If `sbatch` fails with `AssocGrpSubmitJobsLimit`: check `sacctmgr show assoc where account=${ACCOUNT} format=Account,User,GrpSubmit`. If `GrpSubmit=0`, account submission is restricted.
   - If AWS compute nodes fail to launch: check `/var/log/parallelcluster/clustermgtd`. If repeated bootstrap failures occur (e.g. `InsufficientInstanceCapacity`, credit exhaustion, or quota limits), ParallelCluster sets the compute fleet to `PROTECTED` mode. Re-enabling requires `pcluster update-compute-fleet --status START_REQUESTED` after resolving the underlying AWS issue.
3. **Unset `$WRF_DIR`:** If `configure` or `compile` throws `Cannot find WRF I/O libraries`, verify `export WRF_DIR=/path/to/compiled/WRF` points to an existing, fully compiled WRF tree.
4. **Missing JasPer / GRIB2 Libraries:** If `ungrib.exe` compilation fails, verify `JASPERLIB` and `JASPERINC` are exported.
5. **Prefix Mismatch:** The `fg_name` parameter in `namelist.wps` must match the file prefix of intermediate files (e.g. `'FILE'` or `'FILE_unnc_sfc', 'FILE_unnc_ml'`).

---

## 4. Automated CAMS Hybrid-Level WPS Conversion (`cams_to_wps.py`)

In the operational forecasting pipeline, `ungrib.exe` is bypassed for ECMWF CAMS analysis and forecasts:
1. **Direct WPS Binary Generation**: `cams_to_wps.py` unpacks 137 ECMWF hybrid sigma-pressure model levels and surface NetCDFs directly into Fortran unformatted WPS binary files (`FILE:YYYY-MM-DD_HH`).
2. **Dynamic 3D Full-Pressure Calculation**: Midpoint layer pressures are calculated directly from hybrid coefficients ($a_k, b_k$) stored in `GRIB_pv` metadata.
3. **Surface Geopotential to Height (`SOILHGT`)**: Converts `surface_geopotential` ($z$) into geopotential height (`SOILHGT = z / 9.80665`) and sets required metadata flags (`FLAG_SOILHGT: 1`, `FLAG_PSFC: 1`, `FLAG_SLP: 1`).
4. **Platform-Independent Execution**:
   ```bash
   python -m oper_forecast.cli run-wps --config config/models/wrfchem_cams.yaml --cluster aws_pcluster --date YYYY-MM-DD
   ```
