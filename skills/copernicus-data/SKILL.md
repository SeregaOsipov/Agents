---
name: copernicus-data
description: Comprehensive operational guide for downloading atmospheric and climate datasets from Copernicus ADS/CDS (CAMS Forecasts, CAMS EAC4 Reanalysis, GFAS, ERA5) using cdsapi. Covers native GRIB retrieval, local cfgrib CDM NetCDF conversion, 10,000-field dense request packing, ThreadPoolExecutor queue pipelining, forecast vs analysis semantics, and daily NetCDF slicing for WRF and ICON modeling.
---

# Copernicus ADS/CDS Data Access Runbook

This skill provides operational standards, constraints, and high-throughput recipes for acquiring data from the ECMWF Copernicus Atmosphere Data Store (ADS) and Climate Data Store (CDS).

---

## 1. Authentication & API Endpoints

Access to Copernicus services requires the `cdsapi` package (`>= 0.7.0`) and credentials stored in `~/.cdsapirc`.

### ADS Configuration (`~/.cdsapirc` for CAMS)
```ini
url: https://ads.atmosphere.copernicus.eu/api
key: <your-personal-access-token>
```

### CDS Configuration (`~/.cdsapirc` for ERA5/Climate)
```ini
url: https://cds.climate.copernicus.eu/api
key: <your-personal-access-token>
```

---

## 2. Native GRIB Retrieval & Local CDM NetCDF Conversion

### Always Request `'data_format': 'grib'`
Never request `'netcdf'` or `'netcdf_zip'` for large operational 3D retrievals on ADS/CDS:
1. **Server-Side Conversion Bottleneck**: Requesting NetCDF routes the job through a secondary server-side MIR/`cfgrib` conversion queue on ADS, adding massive latency on top of MARS extraction.
2. **Wire Size Bloat**: Server-side `netcdf_zip` produces uncompressed NetCDF files (~6.2 GB per single 3D CAMS chemistry timestep), whereas native GRIB uses CCSDS/second-order packing (~3–4$\times$ smaller transfer size).

### Local GRIB-to-NetCDF Conversion (`cfgrib`)
Convert downloaded `.grib` files locally to CDM-compliant NetCDF using a **streaming, one-variable-and-one-timestep-at-a-time** pattern (`< 300 MB` peak RAM) and a shared on-disk `.idx` file (scanning the GRIB index once instead of once per variable):
```python
import cfgrib.cfmessage, cfgrib.dataset, cfgrib.messages, cfgrib.xarray_store
import netCDF4, numpy as np, xarray as xr

def convert_grib_to_cdm_nc(grib_path: str, nc_path: str, is_3d: bool = False):
    idx_path = f"{grib_path}.idx"
    stream = cfgrib.messages.FileStream(grib_path, errors="ignore")
    index = cfgrib.dataset.open_fileindex(
        stream, computed_keys=cfgrib.cfmessage.COMPUTED_KEYS, indexpath=idx_path
    )
    param_ids = sorted(index["paramId"])
    has_multi_levels = len(index.get("level:float", index.get("level", []))) > 1
    base_bks = {"indexpath": idx_path, "squeeze": False, "errors": "ignore"}
    if is_3d:
        # CRITICAL: preserve GRIB_pv (hybrid A_k, B_k vertical coefficients)
        base_bks["read_keys"] = ["pv"]

    header_written = False
    nc_out = None
    for param_id in param_ids:
        bk = {**base_bks, "filter_by_keys": {"paramId": param_id}}
        for raw_ds in cfgrib.xarray_store.raw_open_datasets(grib_path, bk):
            # Squeeze scalar non-hybrid coords & rename step->forecast_period, time->forecast_reference_time, hybrid->model_level
            ds = _standardize_cfgrib_ds(raw_ds, is_3d=is_3d)
            if is_3d and has_multi_levels and ds.sizes.get("model_level", 0) <= 1:
                continue  # Skip 1-level fields (e.g. paramId=129 geopotential 'z') in 137-level 3D GRIBs
            target_dims = tuple(d for d in ("forecast_period", "forecast_reference_time", "model_level", "latitude", "longitude") if d in ds.dims)
            if not header_written:
                xr.Dataset(coords=ds.coords, attrs=ds.attrs).to_netcdf(nc_path, mode="w")
                nc_out = netCDF4.Dataset(nc_path, mode="a")
                header_written = True
            for var_name, da in ds.data_vars.items():
                nc_var = nc_out.createVariable(var_name, "f4", target_dims, fill_value=np.float32(np.nan))
                # Copy attributes (including GRIB_pv) and stream 1 timestep at a time
                for t_idx in range(ds.sizes["forecast_period"]):
                    nc_var[t_idx, ...] = np.asarray(da.isel(forecast_period=t_idx).values, dtype=np.float32)
            raw_ds.close()
    if nc_out is not None:
        nc_out.close()
```

> [!IMPORTANT]
> 1. **Never Call `.transpose()`, `.sortby()`, or `xr.merge()` on All Unchunked `cfgrib` Variables in RAM Simultaneously**: A 2.7 GB CCSDS-compressed 3D GRIB file expands to >10 GB in float32 per copy; creating 5 copies across `transpose`/`merge`/`sortby`/`to_netcdf` can exceed 100 GB RAM and trigger the Linux OOM killer (`SIGKILL`). Always stream one `paramId` and one `forecast_period` index at a time and reuse `indexpath` across `paramId`s.
> 2. **`read_keys=['pv']` is mandatory for 3D model levels**: Without `'read_keys': ['pv']`, `cfgrib` omits the `GRIB_pv` attribute on 3D variables, which breaks pressure-level derivation in [`cams_to_wps.py`](file:///home/osipovs/Models/operational-forecasting/src/oper_forecast/preprocessing/cams_to_wps.py), [`cams_utils.py`](file:///home/osipovs/workspace/ClimPy/climpy/utils/cams_utils.py), and [`prepare_cams_ic.sh`](file:///home/osipovs/Models/operational-forecasting/src/oper_forecast/preprocessing/prepare_cams_ic.sh).
> 3. **C-Library Thread Safety**: `libeccodes` and `libnetcdf`/`libhdf5` are not thread-safe when invoked simultaneously across threads. Always wrap `convert_grib_to_cdm_nc` in a `threading.Lock()` and write to a `.tmp` file followed by `os.replace()`.

---

## 3. Hard Limits: Request Cost Ceiling (10,000 Fields) & Dense Packing

Copernicus ADS/CDS enforces a hard ceiling of **10,000 data fields** per single API request:

$$\text{Fields} = N_{\text{variables}} \times N_{\text{levels}} \times N_{\text{leadtimes}} \times N_{\text{times}} \le 10{,}000$$

Exceeding 10,000 fields returns `403 Client Error: Forbidden: cost limits exceeded`.

### Why Dense Packing Matters
During daytime operational hours, each request waits **25 to 85 minutes** in the ADS `accepted` queue before MARS extraction starts (`running` takes only 1–4 minutes). Therefore, **minimizing total request count by packing as many lead times into each request as the 10,000-field ceiling allows** is essential.

### Optimal Request Packing for a 5-Day CAMS Forecast (41 Lead Times: `0..120h` 3-hourly, 137 Levels)

| Stream | Variables ($N_{\text{vars}}$) | Levels ($N_{\text{lvls}}$) | Fields per Lead Time | Max Lead Times per Request ($\lfloor 10{,}000 / F_{\text{lt}} \rfloor$) | Recommended Packing (41 Lead Times) | Deterministic File Naming |
| :--- | :---: | :---: | :---: | :---: | :--- | :--- |
| **Surface (2D)** | 24 | 1 | 24 | 416 | **1 request** (all 41 lts = 984 fields) | `cams_sfc_all.grib` |
| **3D Upper-Air Met** | 6 | 137 | 822 | 12 | **4 requests** (12 lts/req = 9,864 fields) or **6 requests** (8 lts/day = 6,576 fields) | `cams_met_chunk_{idx}.grib` |
| **3D Upper-Air Chem** | 60 | 137 | 8,220 | 1 | **41 requests** (1 lt/req = 8,220 fields) | `cams_chem_lt_{lt:03d}.grib` |
| **Total** | — | — | — | — | **46–48 requests** *(down from 123)* | — |

---

## 4. Concurrent Queue Pipelining (`ThreadPoolExecutor`)

* **Sequential Trap (`max_workers=1`)**: Submitting 1 request at a time in a blocking loop forces every chunk to pay the full 30–85 minute ADS `accepted` queue wait sequentially (>50–100 hours total).
* **Over-Parallelization Trap (>20 workers)**: Flooding ADS with dozens of simultaneous connections triggers HTTP 429 rate-limiting or temporary account suspension (`403 Forbidden - User has been disabled`).
* **Optimal Queue Pipelining (`max_workers=5`)**:
  * Use `concurrent.futures.ThreadPoolExecutor(max_workers=5)` where each worker thread instantiates its own thread-local `cdsapi.Client()`.
  * Keeping 5 requests concurrently in the ADS `accepted` queue overlaps the queue wait time: while 1 request is actively `running` on MARS and downloading, 4 requests advance through the queue so the next task starts extracting immediately.
  * **Retry Policy**: Retry transient network or HTTP 5xx/429 errors up to 3 times with exponential backoff (`15 * 2**attempt` seconds) and re-instantiate the thread's `cdsapi.Client()`. **Fail fast immediately on HTTP 400 (`400 Bad Request`)** errors without retrying.

---

## 5. CAMS Global Forecast Dataset Semantics

Dataset ID: `cams-global-atmospheric-composition-forecasts`

| Parameter | `type: 'analysis'` | `type: 'forecast'` |
| :--- | :--- | :--- |
| **Purpose** | Retrospective / hindcasts only | Forward operational forecast cycles |
| **Date meaning** | Valid date of the atmospheric state | Forecast initialization (base) date |
| **Valid lead times** | Strictly `'0'` | `['0', '3', '6', ..., '120']` (3-hourly) |
| **Max horizon** | Past dates only ($T+0$) | 120 hours (5 full days). $>120$ returns HTTP 400 |

### Release Schedule, Archiving Lag & Can You Use `"today"`?
* **Live ADS Catalogue Publication Schedule** (verified via `Last-Modified` headers on `/catalogue/v1/collections/cams-global-atmospheric-composition-forecasts/form.json` and `/constraints.json`):
  * **`00:00 UTC` Forecast Cycle (`time: '00:00'`, `type: 'forecast'`)**: Published to ADS and added to `form.json` (`maxEnd`) at **`~09:59–10:00 UTC` (`~13:00 UTC+3`)** on the same calendar day ("today").
  * **`12:00 UTC` Forecast Cycle (`time: '12:00'`, `type: 'forecast'`)**: Published to ADS and added to `constraints.json` at **`~21:58–22:00 UTC` (`~01:00 UTC+3` the next day)**.
* **When `"today"` is allowed vs. rejected**:
  * **Before `10:00 UTC` (`13:00 UTC+3`)**: Requesting `"today"` (`date: YYYY-MM-DD/YYYY-MM-DD`) fails immediately with `400 Client Error: Bad Request: Request has not produced a valid combination of values` because ADS `maxEnd` is still `"yesterday"`. Morning runs must use `"yesterday"`.
  * **After `10:00 UTC` (`13:00 UTC+3`)**: Requesting `"today"` with `type: 'forecast'` and `time: '00:00'` **is allowed and succeeds** (e.g., an evening operational schedule at `19:00 UTC+3` / `16:00 UTC` runs 6 hours after the `00:00 UTC` forecast is published on ADS).

---

## 6. Memory-Safe Merging & Daily NetCDF Slicing

Downstream modeling systems ([`cams2wrf_main.py`](file:///home/osipovs/workspace/Merra2BC/cams2wrf_main.py), [`prepare_cams_bc.sh`](file:///home/osipovs/Models/operational-forecasting/src/oper_forecast/preprocessing/prepare_cams_bc.sh), and [`cams_to_wps.py`](file:///home/osipovs/Models/operational-forecasting/src/oper_forecast/preprocessing/cams_to_wps.py)) expect daily files named:
```
ECMWF-CAMS_ml_{YYYYMMDD}.nc
ECMWF-CAMS_sfc_{YYYYMMDD}.nc
```
Because a 5-day 3D CAMS forecast spans ~500 GB uncompressed across 41 lead times:
1. Open converted per-chunk NetCDFs lazily using Dask chunking along time: `xr.open_dataset(fp, chunks={"forecast_period": 1})`.
2. Concatenate `met` chunks and `chem` chunks along `forecast_period` with `data_vars="minimal", coords="minimal", compat="override"`, sort by `forecast_period`, and merge via `xr.merge([ds_met, ds_chem], compat="override")`.
3. Group `valid_time` by calendar day (`%Y%m%d`), slice `ds.isel(forecast_period=mask)`, and stream each daily file to disk **one variable and one `forecast_period` index at a time** (`_write_ds_streaming` using `netCDF4.Dataset`), keeping peak RAM `< 250 MB` and avoiding multi-variable Dask memory spikes.
