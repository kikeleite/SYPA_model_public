"""
Compute specific metrics from raw ONS 2025 data files.
"""
import pandas as pd
import numpy as np
import glob
import os

BASE = "/Users/henriqueleite/Desktop/SYPA_model/V2-dc-opf-zonal-intertemporal/data/raw_data"

print("=" * 70)
print("ONS 2025 RAW DATA METRICS")
print("=" * 70)

# ─────────────────────────────────────────────────────────────────────
# 1. Annual wind curtailment (TWh)
# ─────────────────────────────────────────────────────────────────────
print("\n--- 1. ANNUAL WIND CURTAILMENT ---")
wind_files = sorted(glob.glob(os.path.join(BASE, "2025_wind_curtailment", "RESTRICAO_COFF_EOLICA_2025_*.csv")))
total_wind_curt_mwh_half = 0.0
for f in wind_files:
    df = pd.read_csv(f, sep=";", low_memory=False)
    # Convert columns to numeric, coercing errors
    gen = pd.to_numeric(df["val_geracao"], errors="coerce").fillna(0)
    ref = pd.to_numeric(df["val_geracaoreferencia"], errors="coerce")
    # Curtailment = max(0, reference - actual) where reference is not NaN
    mask = ref.notna()
    curt = np.maximum(0, ref[mask] - gen[mask])
    total_wind_curt_mwh_half += curt.sum()
    month = os.path.basename(f).split("_")[-1].replace(".csv", "")
    print(f"  Month {month}: curtailment (MW-halfhour sum) = {curt.sum():,.0f}")

# Each row is a half-hour, so multiply by 0.5 to get MWh
total_wind_curt_mwh = total_wind_curt_mwh_half * 0.5
total_wind_curt_twh = total_wind_curt_mwh / 1e6
print(f"\n  TOTAL WIND CURTAILMENT: {total_wind_curt_mwh:,.0f} MWh = {total_wind_curt_twh:.3f} TWh")

# ─────────────────────────────────────────────────────────────────────
# 2. Annual solar curtailment (TWh)
# ─────────────────────────────────────────────────────────────────────
print("\n--- 2. ANNUAL SOLAR CURTAILMENT ---")
solar_files = sorted(glob.glob(os.path.join(BASE, "2025_solar_curtailment", "RESTRICAO_COFF_FOTOVOLTAICA_2025_*.csv")))
total_solar_curt_mwh_half = 0.0
for f in solar_files:
    df = pd.read_csv(f, sep=";", low_memory=False)
    gen = pd.to_numeric(df["val_geracao"], errors="coerce").fillna(0)
    ref = pd.to_numeric(df["val_geracaoreferencia"], errors="coerce")
    mask = ref.notna()
    curt = np.maximum(0, ref[mask] - gen[mask])
    total_solar_curt_mwh_half += curt.sum()
    month = os.path.basename(f).split("_")[-1].replace(".csv", "")
    print(f"  Month {month}: curtailment (MW-halfhour sum) = {curt.sum():,.0f}")

total_solar_curt_mwh = total_solar_curt_mwh_half * 0.5
total_solar_curt_twh = total_solar_curt_mwh / 1e6
print(f"\n  TOTAL SOLAR CURTAILMENT: {total_solar_curt_mwh:,.0f} MWh = {total_solar_curt_twh:.3f} TWh")

# ─────────────────────────────────────────────────────────────────────
# 3. Total renewable curtailment
# ─────────────────────────────────────────────────────────────────────
print("\n--- 3. TOTAL RENEWABLE CURTAILMENT ---")
total_re_twh = total_wind_curt_twh + total_solar_curt_twh
print(f"  Wind: {total_wind_curt_twh:.3f} TWh")
print(f"  Solar: {total_solar_curt_twh:.3f} TWh")
print(f"  TOTAL: {total_re_twh:.3f} TWh")

# ─────────────────────────────────────────────────────────────────────
# 4. NE wind installed capacity (proxy: max simultaneous generation)
# ─────────────────────────────────────────────────────────────────────
print("\n--- 4. NE WIND INSTALLED CAPACITY (max simultaneous generation proxy) ---")
gen_files = sorted(glob.glob(os.path.join(BASE, "2025_generation", "GERACAO_USINA-2_2025_*.csv")))
max_ne_wind_gen = 0.0
for f in gen_files:
    df = pd.read_csv(f, sep=";", low_memory=False)
    # Filter NE wind
    mask = (df["id_subsistema"] == "NE") & (df["nom_tipousina"].str.contains("EOLI", case=False, na=False))
    wind_ne = df[mask].copy()
    wind_ne["val_geracao"] = pd.to_numeric(wind_ne["val_geracao"], errors="coerce").fillna(0)
    # Sum per timestamp
    gen_by_ts = wind_ne.groupby("din_instante")["val_geracao"].sum()
    if len(gen_by_ts) > 0:
        month_max = gen_by_ts.max()
        max_ne_wind_gen = max(max_ne_wind_gen, month_max)
        month = os.path.basename(f).split("_")[-1].replace(".csv", "")
        print(f"  Month {month}: max NE wind gen = {month_max:,.0f} MW")

print(f"\n  MAX NE WIND SIMULTANEOUS GENERATION: {max_ne_wind_gen:,.0f} MW = {max_ne_wind_gen/1000:.1f} GW")

# ─────────────────────────────────────────────────────────────────────
# 5. CMO annual averages by subsystem
# ─────────────────────────────────────────────────────────────────────
print("\n--- 5. CMO ANNUAL AVERAGES BY SUBSYSTEM ---")
cmo = pd.read_csv(os.path.join(BASE, "CMO_SEMIHORARIO_2025.csv"), sep=";", low_memory=False)
cmo["val_cmo"] = pd.to_numeric(cmo["val_cmo"], errors="coerce")
cmo_avg = cmo.groupby("id_subsistema")["val_cmo"].agg(["mean", "median", "std", "min", "max"])
for sub in ["N", "NE", "SE", "S"]:
    if sub in cmo_avg.index:
        row = cmo_avg.loc[sub]
        print(f"  {sub:>2}: mean = R${row['mean']:.2f}/MWh, median = R${row['median']:.2f}, "
              f"std = R${row['std']:.2f}, min = R${row['min']:.2f}, max = R${row['max']:.2f}")

# ─────────────────────────────────────────────────────────────────────
# 6. SE vs S price relationship
# ─────────────────────────────────────────────────────────────────────
print("\n--- 6. SE vs S PRICE RELATIONSHIP ---")
cmo_pivot = cmo.pivot_table(index="din_instante", columns="id_subsistema", values="val_cmo")
if "SE" in cmo_pivot.columns and "S" in cmo_pivot.columns:
    se_s = cmo_pivot[["SE", "S"]].dropna()
    corr = se_s["SE"].corr(se_s["S"])
    within_1 = (np.abs(se_s["SE"] - se_s["S"]) <= 1.0).mean() * 100
    within_5 = (np.abs(se_s["SE"] - se_s["S"]) <= 5.0).mean() * 100
    exact_match = (se_s["SE"] == se_s["S"]).mean() * 100
    print(f"  Correlation (SE, S): {corr:.4f}")
    print(f"  Exact match (SE CMO == S CMO): {exact_match:.1f}%")
    print(f"  Within R$1 tolerance: {within_1:.1f}%")
    print(f"  Within R$5 tolerance: {within_5:.1f}%")
    print(f"  Mean |SE - S| = R${np.abs(se_s['SE'] - se_s['S']).mean():.2f}/MWh")

# ─────────────────────────────────────────────────────────────────────
# 7. NE-SE transmission capacity
# ─────────────────────────────────────────────────────────────────────
print("\n--- 7. NE-SE TRANSMISSION CAPACITY ---")
tx = pd.read_csv(os.path.join(BASE, "LINHA_TRANSMISSAO.csv"), sep=";", low_memory=False)
# Filter NE-SE lines (either direction)
mask_ne_se = (
    ((tx["id_subsistema_terminalde"] == "NE") & (tx["id_subsistema_terminalpara"] == "SE")) |
    ((tx["id_subsistema_terminalde"] == "SE") & (tx["id_subsistema_terminalpara"] == "NE"))
)
tx_ne_se = tx[mask_ne_se].copy()
print(f"  Number of NE-SE transmission lines: {len(tx_ne_se)}")

# Check available capacity columns
cap_col = "val_capacoperlongasemlimit"
tx_ne_se[cap_col] = pd.to_numeric(tx_ne_se[cap_col], errors="coerce")

# Show by direction
for direction in [("NE", "SE"), ("SE", "NE")]:
    d_mask = (tx_ne_se["id_subsistema_terminalde"] == direction[0]) & (tx_ne_se["id_subsistema_terminalpara"] == direction[1])
    subset = tx_ne_se[d_mask]
    total = subset[cap_col].sum()
    print(f"  {direction[0]} -> {direction[1]}: {len(subset)} lines, total capacity = {total:,.0f} MW")

total_cap = tx_ne_se[cap_col].sum()
print(f"  TOTAL NE-SE capacity (both directions): {total_cap:,.0f} MW")

# Also check if there's a deactivation date column to filter active lines only
if "dat_desativacao" in tx_ne_se.columns:
    active = tx_ne_se[tx_ne_se["dat_desativacao"].isna() | (tx_ne_se["dat_desativacao"] == "")]
    active_cap = active[cap_col].sum()
    print(f"  Active lines only: {len(active)} lines, total capacity = {active_cap:,.0f} MW")

print("\n" + "=" * 70)
print("DONE")
print("=" * 70)
