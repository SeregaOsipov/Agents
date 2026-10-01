# ICON Data Processing & Mapping Guide

## Unstructured Grid Mapping
ICON operates natively on an **unstructured icosahedral grid** consisting of triangular cells.

> **WARNING**: Do NOT use `uxarray.Grid.get_spatial_hash()` for mapping spherical coordinates (`[lon, lat]`). It contains a critical bug that can mirror coordinates to the opposite side of the globe.

* **Best Practice:** Convert surface coordinates to 3D Cartesian `[x, y, z]` coordinates and use strictly `scipy.spatial.cKDTree` to map observation locations directly to the native unstructured grid indices.

## Time Level (TL) Parity
ICON's non-hydrostatic dynamical core utilizes a two-time-level integration scheme. 
* Prognostic variables (e.g., `rho`, `vn`, `t_g`) saved in restart files will alternate between `.TL1` and `.TL2` suffixes depending on whether the absolute time step parity is even or odd.
* **Dynamic Resolution:** Python postprocessing scripts must *dynamically* check the NetCDF variables (e.g., using `if "rho.TL2" in ds:`) rather than hardcoding `.TL1` or `.TL2`. If both are detected simultaneously for the same physical field, your code should throw a deliberate error.
* **ART Tracers:** Note that some ICON-ART prognostic tracers (e.g., `dusta`, `dustb`) may bypass this parity and natively save as `.TL2`, but dynamic suffix resolution must remain active globally to ensure robust I/O.
