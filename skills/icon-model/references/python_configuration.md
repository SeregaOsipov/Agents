# Python Configuration Workflow

The operational standard for bootstrapping and configuring ICON simulations is **NOT** manual editing of Bash or Namelist templates. Instead, we rely on centralized `.ini` configurations and Python builder scripts (like `setup_free_run.py` or `setup_ensemble.py`).

## 1. Centralized Configuration (`ensemble_config.ini`)
All core settings for a run are managed within a single configuration file.
```ini
[ensemble]
num_members = 10
template_dir = /shared/scratch/sosipov39/simulations/ICON_run/da/art_global_r02b06_DUST_RAD_template
ensemble_dir = /shared/scratch/sosipov39/simulations/ICON_run/da
restart = False
experiment_start_date = 2019-06-22T00:00:00Z
current_cycle_start = 2019-06-22T00:00:00Z
```
* **`template_dir`**: Points to the read-only directory containing the `exp.testsuite.dust_rad_base` source script and symlinks to grid files.
* **`ensemble_dir`**: The root directory where output run folders (e.g., `free_run/` or `member_001/`) will be generated.
* **`restart`**: Dictates whether the model boots from initial boundary conditions (`False`) or a `.nc` restart file (`True`).

## 2. Python Setup Scripts
Whenever preparing an ICON simulation, use the provided Python setup scripts. For example, `setup_free_run.py`:

```bash
python3 scripts/setup_free_run.py --config ensemble_config.ini
```

### Under the Hood: `ClimPy` Integration
These setup scripts generally utilize `climpy.icon.patch_icon_runscript` (from the local `ClimPy` workspace repository). They automatically:
1. Parse the `.ini` config.
2. Clone the script from `template_dir` to the target execution folder.
3. Use regex to patch variables seamlessly:
   - Sets `export INDIR=...` to the template directory.
   - Sets `export OUTDIR=...` to the isolated execution directory.
   - Replaces `start_date` and `end_date` dynamically.
   - Modifies `lRestart = .true.` or `.false.` depending on the phase of the simulation.
4. Render Slurm execution wrappers (e.g., `run_free_run.slurm`) from Jinja2 (`.j2`) templates to ensure array sizes and partitions match the configuration exactly.

By utilizing this pipeline, you eliminate copy-paste errors and keep execution parameters perfectly synced with the master config.
