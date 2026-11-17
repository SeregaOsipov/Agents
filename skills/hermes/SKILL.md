---
name: hermes
description: >-
  Use this skill when configuring, preprocessing, executing, or debugging the HERMESv3_GR (High-Elective Resolution Modelling Emission System) anthropogenic and biomass-burning emission modeling system and preparing gridded/point emission datasets (EDGAR GHG/AP/VOC, CAMS-GFAS, CAMS-GLOB-SHIP, OMI-HTAPv2, Wiedinmyer, Caseiro, Bourtsoukidis, IASI) for WRF-Chem (including RADM2/MADE-SORGAM + CO2/CH4). All paths are parameterized; ask the user for any missing paths.
---

# HERMESv3_GR Emission Inventory Generation Runbook

This skill documents the end-to-end operational workflow for downloading raw inventories, preprocessing them to CF-1.6 NetCDF inputs, configuring speciation and temporal/vertical profiles, and running MPI-parallel **HERMESv3_GR** to generate WRF-Chem `wrfchemi` / `HERMESv3_*.nc` emission files.

> **CRITICAL AGENT INSTRUCTION (Path Parameterization & Interactive Disambiguation):**
> All paths in this runbook are parameterized. **Do NOT assume hardcoded user paths or cluster mounts.**
> Verify `${EMISSIONS_REPO}`, `${EMISSIONS_DATA_ROOT}`, `${HERMES_WORK_DIR}`, and `${CONDA_ENV}` from the active config (`config.yaml`), environment variables, or user prompt before executing commands. Ask the user if any required path is missing.

---

## Environment Variables & Directory Layout

| Variable | Description | Default / Example Location |
| :--- | :--- | :--- |
| `${EMISSIONS_REPO}` | Unified project repo containing `config.yaml`, `cli/`, `conf/`, `data/`, `downloading/`, `preproc/`, `jobs/`, `postproc/`, and `models/hermesv3_gr` | `${HOME}/workspace/emissions-inventory` |
| `${HERMES_REPO}` | HERMESv3_GR core source submodule (`Serega.Osipov/hermesv3_gr`, branch `middle_east_branch`) | `${EMISSIONS_REPO}/models/hermesv3_gr` |
| `${EMISSIONS_DATA_ROOT}` | Dedicated high-capacity storage root for raw & preprocessed emissions | `/HDD1/Data/emissions` |
| `${HERMES_WORK_DIR}` | HERMES runtime root holding `HERMES_IN/`, `datasets/`, `HERMES_OUT/` | `${EMISSIONS_DATA_ROOT}/hermes` |
| `${CONDA_ENV}` | Mamba environment (`python=3.11`, `esmpy`, `esmf`, `mpi4py`, `netcdf4`, `cdo`, `python-cdo`, `geopandas`, `cf-units`, `timezonefinder`, `cdsapi`, `eccodes`, `lftp`, `gh`) | `py311_hermes` |

### Runtime Symlink Wiring under `${HERMES_WORK_DIR}`

Keep repository code cleanly separated from large data on `${EMISSIONS_DATA_ROOT}`:
- `${HERMES_WORK_DIR}/HERMES_IN/conf` -> `${EMISSIONS_REPO}/conf`
- `${HERMES_WORK_DIR}/HERMES_IN/data/global_attributes.csv` -> `${EMISSIONS_REPO}/data/global_attributes.csv`
- `${HERMES_WORK_DIR}/HERMES_IN/data/profiles` -> `${EMISSIONS_REPO}/data/profiles`
- `${HERMES_WORK_DIR}/HERMES_IN/data/gadm_country_mask/` hosts the large `gadm_country_ISO3166.*` shapefile (~515 MB; symlinked back to `${EMISSIONS_REPO}/data/gadm_country_mask` and gitignored)
- `${HERMES_WORK_DIR}/datasets/`:
  - `ecmwf/gfas` -> `${EMISSIONS_DATA_ROOT}/CAMS-GFAS/hermesv3_gr_pp`
  - `EDGAR/2024_GHG` -> `${EMISSIONS_DATA_ROOT}/EDGAR/EDGAR_2024_GHG`
  - `EDGAR/v81_AP` -> `${EMISSIONS_DATA_ROOT}/EDGAR/v81_FT2022_AP`
  - `EDGAR/v81_VOC` -> `${EMISSIONS_DATA_ROOT}/EDGAR/v81_FT2022_VOC_spec`
  - `cams_glob_shipv32` -> `${EMISSIONS_DATA_ROOT}/ECCAD/CAMS-GLOB-SHIP/v3.2/hermes_pp`
  - `OMI-HTAP` -> `${EMISSIONS_DATA_ROOT}/OMI-HTAP`
  - `ucar` -> `${EMISSIONS_DATA_ROOT}/ucar`
  - `bourtsoukidisetal` -> `${EMISSIONS_DATA_ROOT}/bourtsoukidisetal`
  - `IASI` -> `${EMISSIONS_DATA_ROOT}/IASI`
  - `caseiroetal` -> `${EMISSIONS_DATA_ROOT}/caseiroetal`
- `${HERMES_WORK_DIR}/HERMES_OUT/`: output NetCDFs, `logs/`, and cached `auxiliary_files/WRF_CHEM_<domain_type>_<resolution>_<nx>_<ny>/`.

---

## 1. Environment Setup

```bash
cd "${EMISSIONS_REPO}"
git submodule update --init --recursive
mamba env create -f environment.yml
mamba activate "${CONDA_ENV}"
pip install --no-deps -e ./models/hermesv3_gr
```

Verify core dependencies (`cdo` and `grib_ls`/`grib_copy` must be on `PATH`):
```bash
python -c "import esmpy, hermesv3_gr, geopandas, cf_units, timezonefinder, cdo; print('OK')"
hermesv3_gr --help
```

---

## 2. Inventory Matrix, Reference Years & Speciation

Active WRF-Chem Middle East / THOFA configurations (`conf/hermes_THOFA_2023.conf` + `conf/EI_configuration_THOFA_WRF_Chem_2023.csv`, and full-year `conf/hermes_2023.conf` + `conf/EI_configuration_WRF_Chem_2023.csv`) combine:

| Inventory | Frequency | Type | Ref Year (2023 runs) | Notes |
| :--- | :--- | :--- | :--- | :--- |
| `GFASv12` | daily | point | target year (`2023` / `2024-01-01` if 366 steps) | Uses `ga_YYYYMMDD.nc` with `apt` (`sovief`) plume injection |
| `EDGAR_2024_GHG` | yearly | area | `2023` | `co2`, `ch4` (`E700` both, `E701` `ch4`-only, `E702` `nmm` `co2`-only) |
| `EDGARv81_AP` | yearly | area | `2022` | Air pollutants (`nox_no2`, `co`, `so2`, `nh3`, `pm10`, `bc`, `oc`, `pm25`) |
| `EDGARv81_VOC` | yearly | area | `2022` | `voc1`–`voc25`; 2022 lacks `voc11` in `fuel_exploitation` (`E960`) and `voc16`,`voc20` in `waste` (`E961`) |
| `CAMS-GLOB-SHIP_v32` & `_voc` | daily | area | `2022` | Raw dataset ends `2022-12-31`; set `ref_year=2022` for 2023 runs (`E190` includes `co2`, `ch4`, APs; `E959` VOCs) |
| `OMI-HTAPv2` | monthly | area | `2017` | `so2` (`surface`, `elevated`) |
| `wiedinmyer` | yearly | area | `2010` | Trash burning (`E009`) |
| `bourtsoukidis` | yearly | point | `2020` | Red Sea trace gases (`ch4`, alkanes) |
| `iasi` | yearly | point | `2016` | Red Sea `nh3` |
| `caseiro` | yearly | area | `2017` | Gas flaring (`bc` + co-emitted `so4`) |

### `CO2` & `CH4` (`E_CO2`, `E_CH4`) Configuration
`data/profiles/speciation/Speciation_profile_radm2_madesorgam_WRF_CHEM_AQABA.csv` defines `33` `E_*` output species, including `E_CO2` (`mol.h-1.km-2`):
- **`E190`**: `CAMS-GLOB-SHIP_v32` maps `co2 -> E_CO2`, `ch4 -> E_CH4`.
- **`E700`**: `EDGAR_2024_GHG` joint sectors (`ags`, `che`, `ene`, `ind`, `iro`, `pro_fff`, `rco`, `ref_trf`, `swd_inc`, `tnr_aviation_lto`, `tnr_other`, `tro`) map both `co2 -> E_CO2` and `ch4 -> E_CH4`.
- **`E701`**: `EDGAR_2024_GHG` CH4-only sectors (`awb`, `enf`, `mnm`, `pro_coal`, `pro_gas`, `pro_oil`, `swd_ldf`, `wwt`) map `ch4 -> E_CH4`.
- **`E702`**: `EDGAR_2024_GHG` non-metallic minerals sector (`nmm`) maps `co2 -> E_CO2`.
*(Note: Earlier runs without `EDGAR_2024_GHG` / `E_CO2` produced `32` `E_*` species.)*

---

## 3. Dataset Acquisition & Preprocessing

Ensure `${CONDA_ENV}/bin` is on `PATH` (for `cdo`, `unzip`, `grib_ls`, `grib_copy`) and `PYTHONPATH` includes `${EMISSIONS_REPO}:${HERMES_REPO}`.

### A. EDGAR (`EDGAR_2024_GHG`, `v81_FT2022_AP`, `v81_FT2022_VOC_spec`)
Top-level EDGAR `.zip` files only contain country-total `.xlsx` tables. Gridded HERMES inputs require per-sector `*_flx_nc.zip` fluxes from `jeodpp.jrc.ec.europa.eu`:
```bash
python -u "${EMISSIONS_REPO}/downloading/download_edgar_flx_nc.py" --workers 8
python -u "${EMISSIONS_REPO}/preproc/edgar_v81_preproc.py" --stream EDGAR_2024_GHG --years 2023
python -u "${EMISSIONS_REPO}/preproc/edgar_v81_preproc.py" --stream v81_FT2022_AP --years 2022
python -u "${EMISSIONS_REPO}/preproc/edgar_v81_preproc.py" --stream v81_FT2022_VOC_spec --years 2022
```

### B. CAMS-GFAS (`GFASv12`, ADS `cams-global-fire-emissions-gfas`)
> [!IMPORTANT]
> 1. **Multi-Day Chunk Packing**: Each day has `46` fields (~`1.19 GB` uncompressed GRIB1). Use `--chunk_days 4` (`184` fields / ~`4.4 GB` per request, avoiding ADS `IncompleteRead` connection drops seen on larger multi-GB chunks while staying well under ADS's `10,000`-field limit) and `grib_copy [dataDate]` splitting instead of single-day queue waits.
> 2. **Server-Side Duplicate GRIB Records**: On isolated dates (e.g., `2023-05-24` with `64` records and `2023-06-03` with `48` records), Copernicus ADS returns duplicate `paramId` messages that cause `cdo copy` to fail (`Parameter not defined at timestep 1`). Both `download_CAMS_GFAS.py` and `gfas12_preproc.py` run `ensure_unique_grib_params` (`grib_ls` + `grib_copy`) to retain the first record per `paramId` (`46` unique parameters).
> 3. **GRIB1 & GRIB2 Compatibility (`gfas12_preproc.py`)**: Maps GRIB2 variable names via NetCDF `param` code attributes when `cdo` does not emit `var<code>` names, and fills `mami` (`param 119`) from `apt` (`param 120`) when `119` is absent in GRIB2.
> 4. **366th Timestep**: Full-year runs configured with `output_timestep_num = 366` (e.g., `2023/01/01` + `366` daily steps) also read `YYYY+1-01-01` (`ga_20240101.nc`).

```bash
python -u "${EMISSIONS_REPO}/downloading/download_CAMS_GFAS.py" --start_date 2023-01-01 --end_date 2024-01-01 --workers 4 --chunk_days 4
python -u "${EMISSIONS_REPO}/preproc/gfas12_preproc.py" --start_date 2023-01-01 --end_date 2024-01-01 --workers 8
```

### C. CAMS-GLOB-SHIP v3.2 (`2022`) & Static Annual/Monthly Inventories
```bash
# Daily shipping (APs + HTAPv3-speciated VOCs; skips existing outputs unless --overwrite)
python -u "${EMISSIONS_REPO}/preproc/cams_glob_ship_v32_preproc.py" --start_date 2022-01-01 --end_date 2022-12-31 --workers 8
python -u "${EMISSIONS_REPO}/preproc/cams_glob_ship_v32_voc_preproc.py" --start_date 2022-01-01 --end_date 2022-12-31

# Monthly / yearly static inventories
python -u "${EMISSIONS_REPO}/preproc/omi_htapV2_preproc.py"
python -u "${EMISSIONS_REPO}/preproc/wiedinmyer_preproc.py"
```

---

## 4. Running HERMESv3_GR & Output Verification

Launch via `${EMISSIONS_REPO}/jobs/` (auto-selects `srun` on Slurm or `mpirun -np "${NTASKS}"` locally):
```bash
NTASKS=24 bash "${EMISSIONS_REPO}/jobs/hermesv3_gr_thofa_2023.sh" > "${HERMES_WORK_DIR}/hermes_thofa_2023.log" 2>&1
# Or full-year 2023:
NTASKS=24 bash "${EMISSIONS_REPO}/jobs/hermesv3_gr_2023.sh" > "${HERMES_WORK_DIR}/hermes_2023.log" 2>&1
```

### Domain-Agnostic `geo_em` CLI & 2023 Climatology (`cli/`)
For arbitrary WRF `geo_em.d0*.nc` grids (extracting LCC projection metadata directly from `geo_em`, guarding cold-start `temporal_coords.nc` / `timezones.nc` / shapefile initialization with an `fcntl` lock, mapping Feb-29 shipping to 2022-02-28, and supporting `--gfas-mode` `nrt_persist` | `historical` | `off`):
```bash
bash "${EMISSIONS_REPO}/jobs/run_hermes_wrf_domain.sh" \
  --start-date "${START_DATE}" \
  --days "${DAYS}" \
  --geo-em "${GEO_EM_FILE}" \
  --out-file "${OUT_FILE}" \
  --cluster "${CLUSTER_PROFILE}" \
  --ntasks "${NTASKS}" \
  --gfas-mode nrt_persist

# Build 366-day 2023 baseline fallback NetCDFs per domain:
python "${EMISSIONS_REPO}/cli/build_climatology_2023.py" \
  --geo-em-dir "${WPS_DOMAIN_DIR}" \
  --out-dir "${CLIM_OUT_DIR}" \
  --cluster "${CLUSTER_PROFILE}" \
  --ntasks "${NTASKS}" \
  --gfas-mode historical
```

### Known Pitfalls & Debugging
1. **First-Run `temporal_coords.nc` MPI Barrier Race Condition (`grid_lcc.py`)**:
   In `models/hermesv3_gr/hermesv3_gr/modules/grids/grid_lcc.py`, `settings.comm.Barrier()` is indented *inside* `if not os.path.exists(self.coords_netcdf_file):`. When launching with `NTASKS > 1` on a clean auxiliary directory (`erase_auxiliary_files = 1` or a new domain), a slower rank can see the initial file created by Rank 0 before Rank 0 overwrites it with `cell_area`, skip the barrier, hit `FileNotFoundError`, and leave remaining ranks deadlocked at `Barrier()`. If starting from an empty `auxiliary_files/` directory, initialize once with `NTASKS=1` until `temporal_coords.nc` exists (or re-run once after Rank 0 finishes writing `temporal_coords.nc`), or use `cli/generate_wrfchemi.py` which automates `--first_time True` under `fcntl` locking.
2. **Rank-Count Tied Weight Matrices**:
   Regridding weight files are named `Weight_Matrix_<inventory>_<NTASKS>.nc` under `WRF_CHEM_<domain_type>_<resolution>_<nx>_<ny>/`. Keeping `NTASKS=24` reuses existing weight matrices and avoids re-computing them.
3. **Middle East Weekend Profile**:
   Ensure `p_week = <input_dir>/data/profiles/temporal/TemporalProfile_Weekly_islamic.csv` (Friday–Saturday weekend) is set in `.conf`.
4. **PROJ stderr noise**:
   `ERROR 1: PROJ: proj_create_from_database: Open of .../share/proj failed` may appear during `PointGfasEmissionInventory` regridding due to deprecated `{'init': 'epsg:4326'}` CRS syntax in upstream `point_gfas_emission_inventory.py`; verify `timezones.nc` and output `E_*` fields directly.
5. **Single-Invocation Multi-Step vs Day-by-Day Stepping (`hermes.py`)**:
   Upstream `HermesGr` initializes daily/monthly inventories once at `start_date` and applies 3D temporal factors (`p_month`, `p_week`, `p_day`, `p_hour`) across `output_timestep_num`; use `end_date > start_date` or `cli/generate_wrfchemi.py` when daily-varying fire/shipping files must step day-by-day.

### Verification Checklist
- Confirm `***** HERMESv3_GR simulation finished successfully *****` in Rank 0 log under `${HERMES_WORK_DIR}/HERMES_OUT/logs/`.
- Inspect output NetCDF with `netCDF4`:
  - `Times` length matches `output_timestep_num`, starting at `start_date`.
  - All `33` `E_*` species present (`E_CO2`, `E_CH4`, `E_CO`, `E_NO`, `E_SO2`, `E_NH3`, `E_PM_10`, `E_ECJ`, `E_ORGJ`, RADM2 VOCs) with `0` NaNs.
  - Expected `0` species under `Speciation_profile_radm2_madesorgam_WRF_CHEM_AQABA.csv`: `E_CSL`, `E_PM25I`, `E_PM25J`, `E_NO3I`, `E_NO3J`, `E_SO4J`.
