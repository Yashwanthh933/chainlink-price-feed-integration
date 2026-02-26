# ☕ TeaShop — Chainlink Price Feed Integration

A decentralized shop contract that accepts ETH payments at live USD prices using Chainlink oracles. Built as a learning project to deeply understand how price feeds work, how decimals are handled, and how to write safe oracle consumers.

---

## What This Project Covers

- Consuming a Chainlink `AggregatorV3Interface` price feed
- Normalizing 8-decimal feed output to 18-decimal precision dynamically
- All 5 oracle safety checks (staleness, negative price, stale round, incomplete round, decimals)
- The unit mismatch bug — why `USD stored values ≠ ETH wei` and how to avoid it
- Refunding excess ETH to buyers correctly (in wei, not USD)
- Unit tests with `MockV3Aggregator` vs fork integration tests with real Chainlink on Sepolia
- Why `makeAddr()` addresses cannot receive ETH via `.call` in fork mode

---

## How Prices Work

### Owner Sets Price in USD

```solidity
teaShop.addItem("Bellam Coffee", 5); // $5
```

Internally stored as `5e18` — USD with 18 decimal precision. This is standard practice to avoid floating point.

### Buyer Queries Price in ETH

```solidity
uint256 ethRequired = teaShop.getItemPriceInEth(0);
```

The contract reads the live ETH/USD price from Chainlink and converts:

```
ethRequired = (usdPrice * 1e18) / ethPriceUsd
            = (5e18 * 1e18) / 2000e18       ← at $2000/ETH
            = 2500000000000000               = 0.0025 ETH
```

### Buyer Pays in ETH

```solidity
teaShop.buyItem{value: ethRequired + 1}(0); // +1 wei for integer division truncation
```

The contract checks `msg.value >= getItemPriceInEth(_itemId)` directly in wei — no round-trip USD conversion. Any excess is automatically refunded.

---

## Decimal Handling Deep Dive

Chainlink ETH/USD returns prices with **8 decimals**:

```
Raw answer: 200000000000  (= $2000.00 with 8 dec)
```

We normalize to **18 decimals** to match ETH's precision:

```solidity
// feedDecimals = 8, targetDecimals = 18
return uint256(answer) * 10 ** (18 - 8);
// = 200000000000 * 1e10
// = 2000000000000000000000  (= $2000.00 with 18 dec) ✅
```

Why 18 decimals? Because ETH amounts are in wei (18 decimals), so keeping prices in the same scale lets us do clean arithmetic without precision loss:

```
USD value of X ETH = (ethPrice_18dec × ethAmount_18dec) / 1e18
                   = (2000e18 × 0.0025e18) / 1e18
                   = 5e18 = $5.00 ✅
```

The library handles this dynamically — if Chainlink ever changes the feed's decimals, the normalization still works correctly.

---

## Oracle Safety Checks

Every call to `PriceConverter.getPrice()` validates 3 things:

| Check | Code | What It Catches |
|---|---|---|
| **Staleness** | `block.timestamp - updatedAt > 1 hours` | Feed stopped updating (node down, network issue) |
| **Negative price** | `answer < 0` | Feed malfunction or data corruption |
| **Stale round** | `answeredInRound < roundId` | Answer carried over from a previous round |

If any check fails, the transaction reverts — protecting users from buying at a stale or corrupted price.

---

## The Unit Mismatch Bug

This is the most important concept in the project. There are two completely different units in play:

```
items[_itemId].price  → USD  (e.g. 5e18 = $5.00)
msg.value             → ETH  (e.g. 5e18 = 5 ETH = $10,000 at $2000/ETH)
```

**Wrong approach (previous bug):**
```solidity
uint256 excess = msg.value - items[_itemId].price;
// 5e18 wei  -  5e18 USD  =  0
// User paid $10,000 for a $5 item and got $0 refunded ❌
```

**Correct approach:**
```solidity
uint256 requiredEth = getItemPriceInEth(_itemId); // converts USD → wei
uint256 excess = msg.value - requiredEth;          // both in wei ✅
```

Rule: **never subtract or compare values in different units. Always convert to the same unit first.**

---

## Integer Division Truncation

`getItemPriceInEth` uses integer division which always rounds down:

```
requiredEth = (5e18 * 1e18) / 2000e18 = 2499999999999999  (truncated, not 2500000000000000)
```

When converted back to USD, this truncated value is fractionally less than $5, so sending exactly `getItemPriceInEth()` will revert with `TeaShop_NotSufficient`.

**Always add 1 wei when using `getItemPriceInEth()` to fund a `buyItem` call:**
```solidity
teaShop.buyItem{value: teaShop.getItemPriceInEth(0) + 1}(0);
```

---

## Project Structure

```
TeaShop/
├── src/
│   ├── TeaShop.sol              # Main contract
│   └── PriceConverter.sol       # Oracle library with safety checks
├── script/
│   ├── HelperConfig.s.sol       # Multi-network price feed config
│   └── DeployTeaShop.s.sol      # Deployment script
├── test/
│   ├── unit/
│   │   └── TestTeaShop.t.sol    # Unit tests using MockV3Aggregator
│   ├── integration/
│   │   └── TestTeaShopFork.t.sol # Fork tests against real Chainlink on Sepolia
│   └── mocks/
│       └── MockV3Aggregator.sol  # Chainlink mock for local testing
├── .env                          # RPC URLs and private keys (never commit)
├── .gitignore
└── foundry.toml
```

---

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- A Sepolia RPC URL (from [Alchemy](https://alchemy.com) or [Infura](https://infura.io))

### Install

```bash
git clone https://github.com/Yashwanthh933/TeaShop
cd TeaShop
forge install
```

### Environment Setup

Create a `.env` file (never commit this):

```
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY

```

Add RPC alias to `foundry.toml`:

```toml
[rpc_endpoints]
sepolia = "${SEPOLIA_RPC_URL}"
```

---

## Running Tests

### Unit Tests (no RPC required)

Uses `MockV3Aggregator` with a fixed price of $2000/ETH. Fast, deterministic, offline.

```bash
forge test --match-path test/unit/*
```

### Fork Integration Tests (requires Sepolia RPC)

Tests against the real Chainlink ETH/USD feed on Sepolia. Price-agnostic — reads the live price dynamically.

```bash
forge test --match-path test/integration/* -vvvv
```

### All Tests

```bash
forge test
```

---

## Deployment

### Local Anvil

```bash
forge script script/DeployTeaShop.s.sol
```

### Sepolia Testnet

```bash
source .env
forge script script/DeployTeaShop.s.sol:DeployTeaShop --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
  --broadcast
```

---

## Supported Networks

| Network | Chain ID | Price Feed |
|---|---|---|
| Anvil (local) | 31337 | MockV3Aggregator ($2000, 8 dec) |
| Sepolia | 11155111 | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| Arbitrum Sepolia | 421614 | `0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165` |
| Mainnet | 1 | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` |

---

## Key Lessons Learned

**1. Chainlink feeds return 8 decimals, not 18.**
Always normalize dynamically using `priceFeed.decimals()` — never hardcode `* 1e10`.

**2. Round-trip precision loss is real.**
Converting USD→ETH→USD via integer division loses a fraction of a wei each time. Compare in one unit only.

**3. `makeAddr()` addresses cannot receive ETH via `.call` in Foundry fork mode.**
Use a contract with `receive()` as the buyer in any test that triggers a refund.

**4. Stale price checks must use the heartbeat of the specific feed.**
Chainlink ETH/USD heartbeat is 1 hour on most networks — but check the docs for each feed.

**5. Mock tests and fork tests serve different purposes.**
Mocks test business logic with deterministic prices. Fork tests verify real oracle integration. Both are needed.

---

## License

MIT
