#!/bin/bash
# =============================================================================
# Helper Script: ICON Execution Environment Validator
# =============================================================================
# Usage: ./validate_icon_setup.sh <path_to_run_directory>
# This script ensures the directory has the proper symlinks and limits set up.

RUN_DIR=$1
if [ -z "$RUN_DIR" ]; then
    echo "Usage: $0 <path_to_run_directory>"
    exit 1
fi

echo "Validating ICON setup in: $RUN_DIR"

if [ ! -d "$RUN_DIR" ]; then
    echo "❌ Error: Run directory does not exist."
    exit 1
fi

cd "$RUN_DIR"

# 1. Check for basic execution script
if [ ! -f "exp.testsuite.dust_rad_base" ]; then
    echo "⚠️ Warning: Could not find exp.testsuite.dust_rad_base in the run directory."
else
    echo "✅ Found execution script."
fi

# 2. Check for restart symlink if lresume might be active
# (A basic heuristic - if restart_ATMO is linked, it should point to a valid file)
if [ -L "restart_ATMO_DOM01.nc" ]; then
    TARGET=$(readlink restart_ATMO_DOM01.nc)
    if [ ! -f "$TARGET" ]; then
        echo "❌ Error: restart_ATMO_DOM01.nc is a broken symlink pointing to missing file: $TARGET"
        exit 1
    else
        echo "✅ Restart symlink is valid."
    fi
fi

# 3. Check for Grid Files
if ls *icon_grid* >/dev/null 2>&1; then
    echo "✅ Grid files present."
else
    echo "⚠️ Warning: No files matching *icon_grid* found. Check your grid symlinks."
fi

echo "============================================================================="
echo "Validation complete. Remember to ensure 'ulimit -s unlimited' is set inside"
echo "your Slurm script before executing mpirun!"
echo "============================================================================="
