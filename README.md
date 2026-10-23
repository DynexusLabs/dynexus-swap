# Dynexus Swap

**Dynexus Swap** is the decentralized exchange (DEX) and automated market maker (AMM) module within the [Dynexus](https://github.com/DynexusLabs/dynexus) DeFi ecosystem.

It enables permissionless token swaps and liquidity pool creation for DYNA and any custom tokens created through [Dynexus Forge](https://github.com/DynexusLabs/dynexus-forge).

---

## 💱 Features

- ✅ Create new liquidity pools between any supported tokens
- 🔄 Swap tokens with constant product (x * y = k) logic
- 💧 Add or remove liquidity from existing pools
- 🧩 Modular design for future incentives and routing
- 🔗 Built with Aptos Move and integrated with DYNA token standards

---

## 🧠 How It Works

1. **Users create tokens** with Dynexus Forge
2. **Pools are created** via Dynexus Swap using those tokens
3. **Swaps occur** through a Curve-like AMM model
4. **Incentives** and voting (coming soon) are managed through [Dynexus Core](https://github.com/DynexusLabs/dynexus-core)

---

## 🛠 Development

Make sure you have the Aptos CLI installed.

### 🧪 Run Tests

```bash
aptos move test
```
