# DePIN Competitor Landscape: 12 Protocols Where Operators Earn Tokens for Coverage, Compute, Storage, and Sensor Data

This report profiles twelve Decentralized Physical Infrastructure Network (DePIN) protocols across four supply-side categories — wireless coverage, decentralized compute (including AI), decentralized storage, and sensor/IoT data. Each protocol is documented across twelve fields, with every value linked to a source URL fetched during research. Where a value could not be confirmed from a fetched source, the cell reads "n.a." and still cites the page that was checked. A comparative synthesis follows the twelve profiles.

---

## 1. Helium (Nova Labs)

| Field | Value |
|---|---|
| Project & token (legal entity + symbol) | Helium, developed by Nova Labs; native token [HNT](https://www.helium.com/) |
| Category | Wireless coverage — LoRaWAN IoT plus 5G/Wi-Fi "Mobile" ([Helium](https://www.helium.com/)) |
| Chain / L2 | [Solana](https://www.coingecko.com/learn/what-is-helium-hnt) (migrated from its own L1 to Solana in April 2023) |
| What operator provides | Physical hotspots providing LoRaWAN IoT and 5G/Wi-Fi wireless coverage ([DePIN Run operator guide](https://www.depinrun.com/guides/helium-hotspot-operator-guide)) |
| Reward mechanism | Proof of Coverage (PoC) for IoT; under [HIP-138](https://www.depinrun.com/guides/helium-hotspot-operator-guide) HNT became the sole reward token and IOT/MOBILE sub-tokens no longer receive separate emissions |
| Token supply / emission schedule | Max supply 223M HNT with a 2-year halving schedule ([CoinGecko](https://www.coingecko.com/learn/what-is-helium-hnt)) |
| Current active nodes / hotspots | 371,314 hotspots as of May 4, 2026 per Explorer ([DePIN Run](https://www.depinrun.com/guides/helium-hotspot-operator-guide)); ~380,900 total in Q2 2025 ([XT blog](https://www.xt.com/en/blog/post/helium-network-surges-138-5-in-data-offloading-as-hotspots-top-380k)) |
| Demand side / who pays | Carriers offloading traffic and IoT data buyers; AT&T pays for Wi-Fi offload across 94,000+ hotspots ([Wi-Fi NOW](https://wifinowglobal.com/news-and-blog/editorial-heliums-partnership-with-att-ushers-in-a-new-era-in-wi-fi-offload/)) |
| Hardware cost (operator entry, USD) | Helium Mobile indoor $249, outdoor $499 ([DePIN Run](https://www.depinrun.com/guides/helium-hotspot-operator-guide); [Helium Deploy hardware](https://heliumdeploy.com/collections/hardware)) |
| Estimated operator monthly reward | IoT community-reported $0.05–$5/month; Mobile often under $1 or near $0 without carrier offload ([DePIN Run](https://www.depinrun.com/guides/helium-hotspot-operator-guide)) |
| Notable partnerships / clients | AT&T Wi-Fi offload ([Wi-Fi NOW](https://wifinowglobal.com/news-and-blog/editorial-heliums-partnership-with-att-ushers-in-a-new-era-in-wi-fi-offload/)); T-Mobile ([Amir Haleem / X](https://x.com/amirhaleem/status/1998410621633933419)) |
| Silicon-anchoring | YES — an ECC608 crypto chip is required per HIP-19, stores the swarm_key, is soldered to the board, and ties the hotspot to a Solana Hotspot NFT ([MNTD support](https://support.getmntd.com/hc/en-us/articles/24583692236695); [Helium maker security requirements](https://docs.helium.com/hotspot-makers/become-a-maker/security-requirements/); [Microchip ECC608-TNGHNT](https://www.microchip.com.cn/newcommunity/Uploads/202304/64421b31503df.pdf)) |

---

## 2. Pollen Mobile

| Field | Value |
|---|---|
| Project & token (legal entity + symbol) | Pollen Mobile, a subsidiary of Pronto AI (founded by Anthony Levandowski); token PollenCoin ([PCN](https://techcrunch.com/2022/02/02/anthony-levandowskis-latest-moonshot-is-a-decentralized-cellular-network-with-crypto-rewards/)) |
| Category | Consumer 5G/CBRS wireless coverage ([TechCrunch](https://techcrunch.com/2022/02/02/anthony-levandowskis-latest-moonshot-is-a-decentralized-cellular-network-with-crypto-rewards/)) |
| Chain / L2 | [Solana](https://coinmarketcap.com/currencies/pollen-coin/) |
| What operator provides | "Flower" radios providing CBRS cellular coverage; "Bumblebee" validators and "Hummingbird" eSIM devices ([The Wireless Miner](https://thewirelessminer.com/2022/03/10/pollen-mobile-a-decentralized-cellular-network/)) |
| Reward mechanism | Proof of Coverage — operators earn PCN for verified coverage ([The Wireless Miner](https://thewirelessminer.com/2022/03/10/pollen-mobile-a-decentralized-cellular-network/)) |
| Token supply / emission schedule | Fixed max supply 1,000,000,000 PCN pegged to $0.10 internal value; 500M incentive pool over 10 years with halvings (first ~Aug 2023 to 1.05M/week; second ~Sep 2026 to 525K/week) ([Pollen payments docs](https://docs.pollenmobile.io/pollen-mobile-docs/white-paper/payments); [network concepts](https://docs.pollenmobile.io/pollen-mobile-docs/white-paper/network-concepts)) |
| Current active nodes / hotspots | n.a. ([CoinMarketCap](https://coinmarketcap.com/currencies/pollen-coin/) lists circulating supply as 0 and does not publish an active-node count) |
| Demand side / who pays | Subscribers purchasing connectivity; network ownership expressed via Solana NFT ([CoinMarketCap](https://coinmarketcap.com/currencies/pollen-coin/)) |
| Hardware cost (operator entry, USD) | Flower radios range from $999 up to over $10,000 ([TechCrunch](https://techcrunch.com/2022/02/02/anthony-levandowskis-latest-moonshot-is-a-decentralized-cellular-network-with-crypto-rewards/)) |
| Estimated operator monthly reward | n.a. ([Pollen payments docs](https://docs.pollenmobile.io/pollen-mobile-docs/white-paper/payments) define reward pools but do not publish a per-operator monthly figure) |
| Notable partnerships / clients | Investors/backers include Slow Ventures and Dish Wireless ([Fierce Network](https://www.fierce-network.com/tech/pollens-diy-network-nothing-sneeze)) |
| Silicon-anchoring | Device ownership is represented via Solana NFT ([CoinMarketCap](https://coinmarketcap.com/currencies/pollen-coin/)); no evidence of a required proprietary crypto chip found in fetched sources |

---

## 3. World Mobile

| Field | Value |
|---|---|
| Project & token (legal entity + symbol) | World Mobile; token [WMTX](https://coinmarketcap.com/currencies/world-mobile-token/) |
| Category | Wireless coverage — rural/underserved mobile connectivity ([World Mobile](https://worldmobile.io/)) |
| Chain / L2 | Originally Cardano; migrated in late 2025 to World Mobile Chain (WMC), an L3 built on Base, with multi-chain support across Ethereum/BNB/Arbitrum ([BingX](https://bingx.com/en/learn/article/what-is-world-mobile-token-wmtx-depin-how-does-it-work); [CoinMarketCap](https://coinmarketcap.com/currencies/world-mobile-token/)) |
| What operator provides | AirNodes provide connectivity; EarthNodes process telco data and stake WMTX ([World Mobile](https://worldmobile.io/)) |
| Reward mechanism | Usage/coverage rewards paid in USD/stablecoins (~$0.0042/GB); EarthNodes stake WMTX to validate ([World Mobile AirNodes](https://worldmobile.io/airnodes); [AirNode guide](https://faq.worldmobiletoken.com/airnode-guide/airnode-models/types-of-airnodes)) |
| Token supply / emission schedule | Max supply 2,000,000,000 WMTX with decelerating emissions and zero inflation by ~2030 ([WMTX tokenomics FAQ](https://faq.worldmobiletoken.com/docs/token-faq/tokenomics/token-metrics-and-distribution)) |
| Current active nodes / hotspots | Claims 1.6M+ users over 24h and 99% USA coverage ([World Mobile](https://worldmobile.io/)); exact active AirNode count n.a. in fetched sources |
| Demand side / who pays | Mobile subscribers and roaming/backhaul partners; connectivity billed per GB ([World Mobile AirNodes](https://worldmobile.io/airnodes)) |
| Hardware cost (operator entry, USD) | EmberNode $165 one-time (tiered); Spark AirNode $49.99–$62.99 ([World Mobile AirNodes](https://worldmobile.io/airnodes); [AirNode guide](https://faq.worldmobiletoken.com/airnode-guide/airnode-models/types-of-airnodes)) |
| Estimated operator monthly reward | n.a. — rewards computed per-GB (~$0.0042/GB) rather than a fixed monthly figure ([World Mobile AirNodes](https://worldmobile.io/airnodes)) |
| Notable partnerships / clients | Protelindo tower partnership ([Investing.com](https://www.investing.com/news/cryptocurrency-news/world-mobile-and-protelindo-partner-to-expand-connectivity)); joined the HAPS Alliance for stratospheric backhaul ([World Mobile Stratospheric](https://worldmobile.io/stratospheric); [Cointelegraph](https://cointelegraph.com/news/world-mobile-launch-world-mobile-stratospheric)) |
| Silicon-anchoring | EarthNodes stake WMTX to validate ([World Mobile](https://worldmobile.io/)); no proprietary crypto-chip requirement found in fetched sources |

---

## 4. DIMO

| Field | Value |
|---|---|
| Project & token (legal entity + symbol) | DIMO Network; token [DIMO](https://docs.dimo.org/overview/dimotoken/token-details-and-distribution) (ERC-20) |
| Category | Sensor/vehicle data — connected-car telemetry ([DIMO docs](https://docs.dimo.org/overview/dimotoken/token-details-and-distribution)) |
| Chain / L2 | Polygon plus Ethereum ([DIMO docs](https://docs.dimo.org/overview/dimotoken/token-details-and-distribution)) |
| What operator provides | Vehicle owners stream telemetry via a plug-in device (Macaron/AutoPi) ([DIMO intro](https://dimo.org/news/introduction-to-dimo)) |
| Reward mechanism | Usage-based weekly rewards with streak-based tiers for connected vehicles ([DIMO earning docs](https://docs.dimo.org/explained/earning-dimo-tokens)) |
| Token supply / emission schedule | Max supply 1,000,000,000; 450M allocated to driver rewards over 40 years at 1,105,000/week in year 1, decreasing 15%/year ([DIMO token details](https://docs.dimo.org/overview/dimotoken/token-details-and-distribution); [earning docs](https://docs.dimo.org/explained/earning-dimo-tokens)) |
| Current active nodes / hotspots | 16,000+ cars cited in a 2023 blog, growing toward 25,000–35,000 ([DIMO intro](https://dimo.org/news/introduction-to-dimo)) |
| Demand side / who pays | Data buyers — insurers, OEMs, fleets and app developers purchasing vehicle data ([DIMO intro](https://dimo.org/news/introduction-to-dimo)) |
| Hardware cost (operator entry, USD) | Macaron $99 (uses Helium IoT for connectivity); AutoPi $349 MSRP ([DIMO AutoPi pricing](https://dimo.co/blogs/the-pit-stop/autopi-returns-to-original-price); [Helium Mart](https://heliummart.com/dimo-network/)) |
| Estimated operator monthly reward | ~€10–15/week at Tier 4 per third-party review ([Adasfera](https://adasfera.com/2026/03/opiniones-dimo-macaron-y-autopi-2026-vale-la-pena/)) |
| Notable partnerships / clients | Uses Helium IoT network for Macaron connectivity ([Helium Mart](https://heliummart.com/dimo-network/)) |
| Silicon-anchoring | Device is minted on-chain as an NFT identity, but no specific chip attestation is required ([DIMO Macaron under the hood](https://dimo.org/news/under-the-hood-of-the-dimo-macaron)) |

---

## 5. Wicrypt

| Field | Value |
|---|---|
| Project & token (legal entity + symbol) | Wicrypt; token Wicrypt Network Token ([WNT](https://coinmarketcap.com/currencies/wicrypt/)) |
| Category | Wireless coverage — Wi-Fi hotspot sharing ([Wicrypt whitepaper](https://whitepaper.wicrypt.com/4.-tokenomics/4.1-wicrypt-network-token-usdwnt)) |
| Chain / L2 | Polygon, with Arbitrum One as default since April 2024 ([CoinMarketCap](https://coinmarketcap.com/currencies/wicrypt/)) |
| What operator provides | Wi-Fi hotspot devices that share metered internet access ([DePINscan](https://depinscan.io/projects/wicrypt)) |
| Reward mechanism | Usage-based mining plus required staking; operators must maintain 10 hrs/week uptime and enable business mode ([Binance Square](https://www.binance.com/en/square/post/1088506407722)) |
| Token supply / emission schedule | Max supply 200,000,000 WNT ([Wicrypt whitepaper](https://whitepaper.wicrypt.com/4.-tokenomics/4.1-wicrypt-network-token-usdwnt); [CoinMarketCap](https://coinmarketcap.com/currencies/wicrypt/)) |
| Current active nodes / hotspots | 39–48 active devices per DePINscan ([DePINscan](https://depinscan.io/projects/wicrypt)) |
| Demand side / who pays | End users buying metered Wi-Fi access; increasingly enterprise/subscription customers ([TechCabal](https://techcabal.com/2026/01/21/wicrypt-startup-selling-internet/)) |
| Hardware cost (operator entry, USD) | Average device cost $211.37 per DePINscan ([DePINscan](https://depinscan.io/projects/wicrypt)) |
| Estimated operator monthly reward | Estimated daily earnings ~$0.23 per DePINscan, implying roughly $7/month ([DePINscan](https://depinscan.io/projects/wicrypt)) |
| Notable partnerships / clients | Live in the peaq ecosystem ([AppsAfrica](https://www.appsafrica.com/wicrypts-web3-wifi-hotspots-go-live-in-the-peaq-ecosystem/)) |
| Silicon-anchoring | No proprietary crypto-chip requirement found; operators stake WNT and meet uptime rules ([Binance Square](https://www.binance.com/en/square/post/1088506407722)) |

---

## 6. Akash Network (Overclock Labs)

| Field | Value |
|---|---|
| Project & token (legal entity + symbol) | Akash Network, developed by Overclock Labs; token [AKT](https://akash.network/token/) |
| Category | Decentralized compute — Kubernetes/GPU cloud marketplace ([Akash](https://akash.network/token/)) |
| Chain / L2 | Own Cosmos SDK L1 using Tendermint Proof-of-Stake ([Akash providers docs](https://akash.network/docs/learn/core-concepts/providers-leases/)) |
| What operator provides | Providers supply idle server/GPU capacity and lock AKT only during active leases ([Akash providers docs](https://akash.network/docs/learn/core-concepts/providers-leases/)) |
| Reward mechanism | Staking inflation plus marketplace lease revenue; a take rate of 4% in AKT / 20% in USDC applies, and a USD-pegged credit (ACT) is created by burning AKT ([Cito tokenomics guide](https://www.cito.zone/cito-research/the-ultimate-akash-(-akt)-tokenomics-guide); [Akash proposal 322](https://akash.valopers.com/proposals/322)) |
| Token supply / emission schedule | Max supply 388.5M (~292M circulating); dynamic inflation 4–8% (currently 8%, with a proposal to cap at 4%) ([Cito tokenomics guide](https://www.cito.zone/cito-research/the-ultimate-akash-(-akt)-tokenomics-guide); [proposal 322](https://akash.valopers.com/proposals/322)) |
| Current active nodes / hotspots | 1,000+ GPUs deployed at ~60% average utilization, with 3.1M deployments in 2025 ([Akash / X](https://x.com/akashnet/status/2009698421116919877)) |
| Demand side / who pays | AI/ML teams and developers renting GPU/compute via leases ([Akash providers docs](https://akash.network/docs/learn/core-concepts/providers-leases/)) |
| Hardware cost (operator entry, USD) | n.a. — operators supply existing/idle servers rather than buying a fixed-price device ([Akash providers docs](https://akash.network/docs/learn/core-concepts/providers-leases/)) |
| Estimated operator monthly reward | n.a. — depends on GPU type, utilization and lease prices ([Akash providers docs](https://akash.network/docs/learn/core-concepts/providers-leases/)) |
| Notable partnerships / clients | Reports 1,000+ GPUs and 3.1M deployments serving AI workloads in 2025 ([Akash / X](https://x.com/akashnet/status/2009698421116919877)) |
| Silicon-anchoring | No proprietary chip; providers stake/lock AKT during leases ([Akash providers docs](https://akash.network/docs/learn/core-concepts/providers-leases/)) |

---

## 7. io.net

| Field | Value |
|---|---|
| Project & token (legal entity + symbol) | io.net; token [IO](https://io.net/tokenomics) (Solana SPL) |
| Category | Decentralized compute — GPU cloud for AI ([io.net](https://io.net/)) |
| Chain / L2 | [Solana](https://io.net/docs/guides/coin/io-coin-allocation) |
| What operator provides | Suppliers connect GPUs from data centers, mining operations, and private clusters, staking IO proportional to capacity ([io.net explorer docs](https://io.net/docs/guides/explorer/homepage)) |
| Reward mechanism | Emissions plus a new Incentive Dynamic Engine (IDE) that replaces fixed inflation with demand-driven USD-targeted rewards and burns 50%+ of revenue ([io.net tokenomics](https://io.net/tokenomics)) |
| Token supply / emission schedule | Max supply 800M; genesis 500M; 300M emitted hourly over 20 years, disinflationary at 8% year 1 declining ~12%/year, with a burn mechanism ([io.net coin allocation](https://io.net/docs/guides/coin/io-coin-allocation); [tokenomics](https://io.net/tokenomics)) |
| Current active nodes / hotspots | 610K GPUs / 395K worker nodes onboarded (2024 claim) ([io.net LinkedIn](https://www.linkedin.com/posts/ionet-official_ionet-depin-gpu-activity)); skeptics estimate far fewer usable ([ChainCatcher](https://www.chaincatcher.com/en/article/2122583)) |
| Demand side / who pays | AI teams and startups renting GPU compute at ~70% below AWS ([io.net](https://io.net/)) |
| Hardware cost (operator entry, USD) | n.a. — suppliers connect existing GPUs rather than a fixed-price device ([io.net explorer docs](https://io.net/docs/guides/explorer/homepage)) |
| Estimated operator monthly reward | n.a. — varies with GPU type, utilization and IDE demand ([io.net tokenomics](https://io.net/tokenomics)) |
| Notable partnerships / clients | Supports models including Z.ai, Moonshot and DeepSeek (models supported, not necessarily paying clients) ([io.net](https://io.net/)) |
| Silicon-anchoring | Devices staked with IO proportional to capacity; no proprietary chip requirement found ([io.net explorer docs](https://io.net/docs/guides/explorer/homepage)) |

---

## 8. Bittensor

| Field | Value |
|---|---|
| Project & token (legal entity + symbol) | Bittensor; token [TAO](https://learnbittensor.org/concepts/tokenomics/tao) |
| Category | Decentralized AI/ML — incentivized machine-intelligence subnets ([Learn Bittensor](https://learnbittensor.org/concepts/tokenomics/tao)) |
| Chain / L2 | Own L1 (Subtensor, Substrate-based, BABE/GRANDPA consensus) ([Taostats validation docs](https://docs.taostats.io/docs/validation)) |
| What operator provides | Miners run GPU inference/ML models within subnets; validators score outputs ([Taostats validation docs](https://docs.taostats.io/docs/validation)) |
| Reward mechanism | Yuma Consensus splits rewards 18% subnet owner / 41% miners / 41% validators ([arXiv](https://arxiv.org/html/2507.02951v1); [Envelop audit](https://index.envelop.is/reports/tao_audit.html)) |
| Token supply / emission schedule | Max supply 21M (Bitcoin-like); first halving Dec 15, 2025 (7,200→3,600 TAO/day; block reward 1→0.5) ([Learn Bittensor](https://learnbittensor.org/concepts/tokenomics/tao); [arXiv](https://arxiv.org/html/2507.02951v1)) |
| Current active nodes / hotspots | 128 active subnets (capped) and ~40,000 miners/validators ([CryptoNews](https://cryptonews.net/news/altcoins/32922397/)) |
| Demand side / who pays | Consumers of subnet outputs (AI inference, data, prediction) and validators staking TAO; dTAO/alpha tokens exist per subnet ([Taostats validation docs](https://docs.taostats.io/docs/validation)) |
| Hardware cost (operator entry, USD) | n.a. — miners run GPUs; a subnet registration costs 2,500 TAO (burned) and validators need a minimum 1,000 TAO stake ([CryptoNews](https://cryptonews.net/news/altcoins/32922397/); [Taostats validation docs](https://docs.taostats.io/docs/validation)) |
| Estimated operator monthly reward | n.a. — varies by subnet performance and Yuma Consensus scoring ([arXiv](https://arxiv.org/html/2507.02951v1)) |
| Notable partnerships / clients | Fair launch with no premine/ICO; ecosystem organized around 128 subnets ([CryptoNews](https://cryptonews.net/news/altcoins/32922397/)) |
| Silicon-anchoring | No specific chip; miners run GPU inference and register/stake TAO ([Taostats validation docs](https://docs.taostats.io/docs/validation)) |

---

## 9. Gensyn

| Field | Value |
|---|---|
| Project & token (legal entity + symbol) | Gensyn (founded by Ben Fielding and Harry Grieve); token [$AI](https://blockeden.xyz/blog/2026/05/05/gensyn-rl-swarm-decentralized-ml-training-ethglobal/) |
| Category | Decentralized compute — machine-learning training ([Gensyn](https://gensyn.ai/)) |
| Chain / L2 | Custom Ethereum L2 rollup (OP Stack/Bedrock) ([BlockEden](https://blockeden.xyz/blog/2026/05/05/gensyn-rl-swarm-decentralized-ml-training-ethglobal/)) |
| What operator provides | Compute for ML training across roles — Submitters, Solvers, Verifiers, Whistleblowers — on any device from MacBook to datacenter ([Gensyn Verde blog](https://blog.gensyn.ai/verde-a-verification-system-for-machine-learning-over-untrusted-nodes/)) |
| Reward mechanism | Verde verification (refereed delegation) plus Probabilistic Proof-of-Learning, with staking and slashing ([Gensyn Verde blog](https://blog.gensyn.ai/verde-a-verification-system-for-machine-learning-over-untrusted-nodes/)) |
| Token supply / emission schedule | Fixed total supply 10 billion $AI; token sale Dec 15, 2025 (3% / 300M at $1B FDV cap); allocation Community Treasury 40.4%, Investors 29.6%, Team 25%, Sale 3% ([BlockEden](https://blockeden.xyz/blog/2026/05/05/gensyn-rl-swarm-decentralized-ml-training-ethglobal/)) |
| Current active nodes / hotspots | RL Swarm testnet reported 12,000+ nodes and 1.5M models trained as of Nov 2025 ([AInvest](https://www.ainvest.com/news/decentralized-ai-prediction-markets-2511/)) |
| Demand side / who pays | Teams needing ML training compute; verification enables trustless outsourced training ([Gensyn Verde blog](https://blog.gensyn.ai/verde-a-verification-system-for-machine-learning-over-untrusted-nodes/)) |
| Hardware cost (operator entry, USD) | n.a. — any device from MacBook to datacenter can participate ([Gensyn Verde blog](https://blog.gensyn.ai/verde-a-verification-system-for-machine-learning-over-untrusted-nodes/)) |
| Estimated operator monthly reward | n.a. ([BlockEden](https://blockeden.xyz/blog/2026/05/05/gensyn-rl-swarm-decentralized-ml-training-ethglobal/) does not publish a per-operator monthly figure) |
| Notable partnerships / clients | Backed by a16z; ships RL Swarm and open-source tooling ([Gensyn](https://gensyn.ai/)) |
| Silicon-anchoring | No specific chip — verification is done via Verde/Proof-of-Learning across heterogeneous hardware ([Gensyn Verde blog](https://blog.gensyn.ai/verde-a-verification-system-for-machine-learning-over-untrusted-nodes/)) |

---

## 10. Render Network

| Field | Value |
|---|---|
| Project & token (legal entity + symbol) | Render Network (associated with OTOY); token RENDER (formerly RNDR) ([Render token metrics](https://know.rendernetwork.com/basics/token-metrics-summary)) |
| Category | Decentralized compute — GPU rendering ([Gate crypto wiki](https://www.gate.com/crypto-wiki/article/render-deep-dive-tokenomics)) |
| Chain / L2 | Migrated from Ethereum to Solana in Nov 2023 (RNDR→RENDER SPL, 1:1) ([Gate crypto wiki](https://www.gate.com/crypto-wiki/article/render-deep-dive-tokenomics)) |
| What operator provides | Node operators supply idle GPUs for rendering jobs ([Render token metrics](https://know.rendernetwork.com/basics/token-metrics-summary)) |
| Reward mechanism | Burn-Mint Equilibrium (BME, RNP-001): jobs priced in fiat, 95% used to buy+burn RENDER after "proof of render" acceptance, with newly minted tokens paid to node operators ([Render whitepaper](https://resources.cryptocompare.com/asset-management/14091/1720797183908.pdf)) |
| Token supply / emission schedule | Max supply raised from 536.87M to 644.25M (107.38M extra over 10 years on Solana); year-1 emissions 9.13M, year-2 5.90M, ~50% to node operators ([Levex](https://levex.com/en/blog/render-tokenomics); [Render Medium](https://medium.com/render-token/update-render-burn-mint-equilibrium-emissions-are-live-0dd50a266b1d)) |
| Current active nodes / hotspots | n.a. ([Render token metrics](https://know.rendernetwork.com/basics/token-metrics-summary) covers token metrics but not a live node count) |
| Demand side / who pays | 3D artists and creators submitting render jobs, notably via OctaneRender (OTOY) ([Render token metrics](https://know.rendernetwork.com/basics/token-metrics-summary)) |
| Hardware cost (operator entry, USD) | n.a. — operators supply existing GPUs rather than a fixed-price device ([Render token metrics](https://know.rendernetwork.com/basics/token-metrics-summary)) |
| Estimated operator monthly reward | n.a. — depends on GPU tier and job volume ([Render token metrics](https://know.rendernetwork.com/basics/token-metrics-summary)) |
| Notable partnerships / clients | OTOY / OctaneRender integration drives demand ([Render token metrics](https://know.rendernetwork.com/basics/token-metrics-summary)) |
| Silicon-anchoring | No proprietary chip; "proof of render" validates completed work before buy-and-burn ([Render whitepaper](https://resources.cryptocompare.com/asset-management/14091/1720797183908.pdf)) |

---

## 11. Filecoin (Protocol Labs)

| Field | Value |
|---|---|
| Project & token (legal entity + symbol) | Filecoin, developed by Protocol Labs; token [FIL](https://github.com/filecoin-project/filecoin-docs/blob/main/basics/what-is-filecoin/crypto-economics.md) |
| Category | Decentralized storage ([Filecoin crypto-economics](https://github.com/filecoin-project/filecoin-docs/blob/main/basics/what-is-filecoin/crypto-economics.md)) |
| Chain / L2 | Own L1 (with FVM/EVM-compatible layer) ([Filecoin crypto-economics](https://github.com/filecoin-project/filecoin-docs/blob/main/basics/what-is-filecoin/crypto-economics.md)) |
| What operator provides | Storage providers supply disk capacity and servers, posting FIL collateral ([Filecoin blog](https://www.filecoin.io/blog/filecoin-features-verifiable-storage)) |
| Reward mechanism | Proof-of-Replication plus Proof-of-Spacetime; storage providers stake FIL collateral subject to slashing ([Filecoin blog](https://www.filecoin.io/blog/filecoin-features-verifiable-storage)) |
| Token supply / emission schedule | Max supply capped at 2 billion FIL (effective ~1.96B); dual minting of 770M baseline (network-growth based, full only at a yottabyte) and 330M simple (6-year half-life), plus a 300M mining reserve; distribution 70% miners / 15% Protocol Labs / 10% Foundation / 5% investors, with vesting concluding Oct 2026 ([Filecoin crypto-economics](https://github.com/filecoin-project/filecoin-docs/blob/main/basics/what-is-filecoin/crypto-economics.md); [Bitget news](https://www.bitget.com/news/detail/12560605377904)) |
| Current active nodes / hotspots | ~684 active storage providers, ~15.5 EiB capacity and ~1.95 EiB stored data as of May 2026 ([Binance Square](https://www.binance.com/en-IN/square/post/326862095069906)) |
| Demand side / who pays | Clients paying to store data (enterprises, archives, Web3 apps) ([Filecoin blog](https://www.filecoin.io/blog/filecoin-features-verifiable-storage)) |
| Hardware cost (operator entry, USD) | n.a. — providers supply their own storage servers, cost varies by scale ([Filecoin crypto-economics](https://github.com/filecoin-project/filecoin-docs/blob/main/basics/what-is-filecoin/crypto-economics.md)) |
| Estimated operator monthly reward | n.a. — depends on committed capacity, deals and block rewards ([Filecoin crypto-economics](https://github.com/filecoin-project/filecoin-docs/blob/main/basics/what-is-filecoin/crypto-economics.md)) |
| Notable partnerships / clients | ~1.95 EiB of client data stored across ~684 providers ([Binance Square](https://www.binance.com/en-IN/square/post/326862095069906)) |
| Silicon-anchoring | No proprietary chip; integrity is enforced cryptographically via PoRep/PoSt and FIL collateral/slashing ([Filecoin blog](https://www.filecoin.io/blog/filecoin-features-verifiable-storage)) |

---

## 12. IoTeX

| Field | Value |
|---|---|
| Project & token (legal entity + symbol) | IoTeX; token [IOTX](https://docs.iotex.io/blockchain/learn-iotex/the-iotx-token) |
| Category | IoT/sensor DePIN infrastructure platform ([IoTeX docs](https://docs.iotex.io/blockchain/learn-iotex/the-iotx-token)) |
| Chain / L2 | Own EVM-compatible L1 using Roll-DPoS consensus ([IoTeX docs](https://docs.iotex.io/blockchain/learn-iotex/the-iotx-token)) |
| What operator provides | Device makers and DePIN projects connect sensors/hardware; W3bstream provides off-chain verifiable compute and ioID provides on-chain device identity ([W3bstream docs](https://docs.iotex.io/depin-infra-modules-dim/w3bstream-depin-verification); [ioID blog](https://iotex.io/blog/ioid-on-chain-device-identity-for-verifiable-depins/)) |
| Reward mechanism | Oracle-attested / verifiable-compute rewards; devices prove data via W3bstream ZK proofs and ioID identity ([W3bstream docs](https://docs.iotex.io/depin-infra-modules-dim/w3bstream-depin-verification)) |
| Token supply / emission schedule | Max supply 10 billion IOTX (~9.44B circulating); ~200M IOTX/year inflationary staking rewards tapering by 2030; Burn-Drop mechanism (900M burned / 100M dropped as the first 1M devices onboard) plus ioID burns ([iq.wiki](https://iq.wiki/wiki/iotex); [IoTeX whitepaper](https://cdn.iotex.io/whitepaper/iotex_whitepaper_eu.pdf); [CoinMarketCap](https://coinmarketcap.com/currencies/iotex/)) |
| Current active nodes / hotspots | 40M+ devices connected (Sep 2025) across 218 projects, ~51 of them DePIN ([IoTeX–Nodle](https://www.prweb.com/releases/iotex-partners-with-nodle-to-bring-780000-devices-on-chain)) |
| Demand side / who pays | DePIN projects building on IoTeX and buyers of verified device data ([IoTeX–GEODNET](https://iotex.io/blog/iotex-and-geodnet-announce-pioneering-collaboration-for-depin-verifiability/)) |
| Hardware cost (operator entry, USD) | n.a. — IoTeX is an infrastructure platform; hardware cost depends on the DePIN project built on it ([IoTeX docs](https://docs.iotex.io/blockchain/learn-iotex/the-iotx-token)) |
| Estimated operator monthly reward | n.a. — depends on the individual DePIN project running on IoTeX ([IoTeX docs](https://docs.iotex.io/blockchain/learn-iotex/the-iotx-token)) |
| Notable partnerships / clients | Nodle (780,000+ devices on-chain) ([IoTeX–Nodle](https://www.prweb.com/releases/iotex-partners-with-nodle-to-bring-780000-devices-on-chain)); GEODNET, with a $100K IOTX quest pool for proof of liveness/location/movement ([IoTeX–GEODNET](https://iotex.io/blog/iotex-and-geodnet-announce-pioneering-collaboration-for-depin-verifiability/)) |
| Silicon-anchoring | Device identity via ioID (NFT/DID) plus W3bstream ZK proofs provides attestation, but not a proprietary crypto chip ([ioID blog](https://iotex.io/blog/ioid-on-chain-device-identity-for-verifiable-depins/); [W3bstream docs](https://docs.iotex.io/depin-infra-modules-dim/w3bstream-depin-verification)) |

---

## Comparative observations

- **Reward-mechanism diversity is the defining feature of the category.** The twelve protocols span at least six distinct verification-and-reward paradigms: Proof of Coverage for wireless location ([Helium](https://www.depinrun.com/guides/helium-hotspot-operator-guide), [Pollen](https://thewirelessminer.com/2022/03/10/pollen-mobile-a-decentralized-cellular-network/)); usage/metered mining ([Wicrypt](https://www.binance.com/en/square/post/1088506407722), [DIMO](https://docs.dimo.org/explained/earning-dimo-tokens)); a Bitcoin-analog Yuma Consensus for machine intelligence ([Bittensor](https://arxiv.org/html/2507.02951v1)); Proof-of-Replication + Proof-of-Spacetime for storage ([Filecoin](https://www.filecoin.io/blog/filecoin-features-verifiable-storage)); Burn-Mint Equilibrium with "proof of render" for GPU rendering ([Render](https://resources.cryptocompare.com/asset-management/14091/1720797183908.pdf)); and Proof-of-Learning/Verde verification for ML training ([Gensyn](https://blog.gensyn.ai/verde-a-verification-system-for-machine-learning-over-untrusted-nodes/)). There is no converging standard — each supply type demands its own proof primitive.

- **Hardware entry costs vary by roughly two orders of magnitude.** The cheapest verified on-ramp is DIMO's $99 Macaron ([DIMO/Helium Mart](https://heliummart.com/dimo-network/)), followed by World Mobile's $49.99–$165 AirNode tiers ([World Mobile](https://worldmobile.io/airnodes)) and Wicrypt's ~$211 average device ([DePINscan](https://depinscan.io/projects/wicrypt)). Helium sits mid-range at $249–$499 ([DePIN Run](https://www.depinrun.com/guides/helium-hotspot-operator-guide)), while Pollen's Flower radios run from $999 to more than $10,000 ([TechCrunch](https://techcrunch.com/2022/02/02/anthony-levandowskis-latest-moonshot-is-a-decentralized-cellular-network-with-crypto-rewards/)). The compute/storage protocols (Akash, io.net, Bittensor, Gensyn, Render, Filecoin) have no fixed device price — operators contribute existing GPUs or servers, so their real entry cost is capital already owned plus token stake.

- **Silicon-anchoring is Helium's most distinctive moat.** Helium uniquely requires a dedicated ECC608 secure-element chip, soldered to each board and mandated by HIP-19, that holds the swarm key and binds the hotspot to its Solana NFT ([MNTD](https://support.getmntd.com/hc/en-us/articles/24583692236695); [Helium maker requirements](https://docs.helium.com/hotspot-makers/become-a-maker/security-requirements/); [Microchip](https://www.microchip.com.cn/newcommunity/Uploads/202304/64421b31503df.pdf)). Every other protocol reviewed anchors identity in software — on-chain NFTs/DIDs ([DIMO](https://dimo.org/news/under-the-hood-of-the-dimo-macaron), [IoTeX ioID](https://iotex.io/blog/ioid-on-chain-device-identity-for-verifiable-depins/)) or cryptographic proofs and staking/slashing ([Filecoin](https://www.filecoin.io/blog/filecoin-features-verifiable-storage), [Gensyn](https://blog.gensyn.ai/verde-a-verification-system-for-machine-learning-over-untrusted-nodes/)) — none mandate a proprietary tamper-resistant ASIC the way Helium does.

- **Demand-side clarity is far stronger on the compute/storage side than on wireless coverage.** Akash, io.net, Render and Filecoin have concrete, priced demand: GPU/render leases and storage deals with named buyers or verified stored volume ([Akash](https://x.com/akashnet/status/2009698421116919877); [Filecoin](https://www.binance.com/en-IN/square/post/326862095069906); [Render](https://know.rendernetwork.com/basics/token-metrics-summary)). Coverage networks are fuzzier: Helium's AT&T/T-Mobile offload deals are the clearest real revenue ([Wi-Fi NOW](https://wifinowglobal.com/news-and-blog/editorial-heliums-partnership-with-att-ushers-in-a-new-era-in-wi-fi-offload/)), whereas Pollen and Wicrypt lean on subscriber/enterprise models whose paying scale is harder to verify ([TechCabal](https://techcabal.com/2026/01/21/wicrypt-startup-selling-internet/)).

- **Token designs are converging on demand-linked, deflationary emissions.** Several protocols have moved away from pure inflation toward mechanisms that tie issuance to real usage and burn revenue: io.net's Incentive Dynamic Engine burns 50%+ of revenue ([io.net](https://io.net/tokenomics)), Render's Burn-Mint Equilibrium burns 95% of fiat-priced job value ([Render whitepaper](https://resources.cryptocompare.com/asset-management/14091/1720797183908.pdf)), Akash introduced a USD-pegged credit funded by burning AKT ([Cito](https://www.cito.zone/cito-research/the-ultimate-akash-(-akt)-tokenomics-guide)), and Bittensor adopted Bitcoin-style halvings ([Learn Bittensor](https://learnbittensor.org/concepts/tokenomics/tao)).

- **Sovereign / rural-infrastructure ambitions cluster around World Mobile and IoTeX.** World Mobile targets underserved connectivity and is extending into a stratospheric HAPS/aerostat layer for backhaul, having joined the HAPS Alliance ([World Mobile Stratospheric](https://worldmobile.io/stratospheric); [Cointelegraph](https://cointelegraph.com/news/world-mobile-launch-world-mobile-stratospheric)). IoTeX positions itself as neutral device-identity and verifiable-compute infrastructure (ioID + W3bstream) that other DePINs build on top of, already spanning 40M+ devices and 218 projects ([IoTeX–Nodle](https://www.prweb.com/releases/iotex-partners-with-nodle-to-bring-780000-devices-on-chain)). These are the two most explicitly "infrastructure-for-others / national-scale" plays in the set.

- **Node-count reporting is inconsistent and sometimes contested.** Helium (371K hotspots, [DePIN Run](https://www.depinrun.com/guides/helium-hotspot-operator-guide)) and Filecoin (~684 providers, [Binance Square](https://www.binance.com/en-IN/square/post/326862095069906)) publish concrete counts, and Bittensor's 128-subnet cap is well defined ([CryptoNews](https://cryptonews.net/news/altcoins/32922397/)). But io.net's 610K-GPU claim is openly disputed, with skeptics estimating only a few hundred usable nodes ([ChainCatcher](https://www.chaincatcher.com/en/article/2122583)), and several others (Pollen, World Mobile, Render) do not publish a reliable live active-node figure — a due-diligence red flag when comparing "network size."

- **Per-operator profitability is largely opaque across the category.** Only a handful of protocols expose anything resembling a monthly yield: Helium's community-reported $0.05–$5/month IoT figure ([DePIN Run](https://www.depinrun.com/guides/helium-hotspot-operator-guide)), Wicrypt's DePINscan-implied ~$7/month ([DePINscan](https://depinscan.io/projects/wicrypt)), and DIMO's ~€10–15/week third-party estimate ([Adasfera](https://adasfera.com/2026/03/opiniones-dimo-macaron-y-autopi-2026-vale-la-pena/)). The compute, storage and AI networks publish no standardized operator-earnings figure, so ROI comparisons across categories remain speculative.

- **The clearest white space for a mesh-drone + edge-AI DePIN is the intersection no incumbent occupies.** The aerial-coverage layer is only partially addressed by World Mobile's stratospheric HAPS work ([World Mobile Stratospheric](https://worldmobile.io/stratospheric)), verifiable edge inference is addressed separately by Gensyn's Proof-of-Learning ([Gensyn](https://blog.gensyn.ai/verde-a-verification-system-for-machine-learning-over-untrusted-nodes/)) and Bittensor's subnets ([Learn Bittensor](https://learnbittensor.org/concepts/tokenomics/tao)), and hardware-anchored attestation is strongest at Helium ([Helium maker requirements](https://docs.helium.com/hotspot-makers/become-a-maker/security-requirements/)) and IoTeX's ioID ([ioID blog](https://iotex.io/blog/ioid-on-chain-device-identity-for-verifiable-depins/)). No single protocol combines a mobile/aerial mesh coverage layer, verifiable on-device AI inference, and tamper-resistant silicon attestation — a mesh-drone + edge-AI network fusing a World Mobile-style aerial layer, Gensyn/Bittensor-style verifiable compute, and Helium-grade chip-anchored identity would sit in genuinely uncontested territory.

- **Chain choice signals a Solana gravitational pull for high-throughput DePIN.** Helium, Pollen, io.net and Render have all landed on Solana ([CoinGecko](https://www.coingecko.com/learn/what-is-helium-hnt); [Pollen](https://coinmarketcap.com/currencies/pollen-coin/); [io.net](https://io.net/docs/guides/coin/io-coin-allocation); [Render](https://www.gate.com/crypto-wiki/article/render-deep-dive-tokenomics)), while sovereign-minded or compute-native projects run their own L1s (Akash on Cosmos, Bittensor on Subtensor, Filecoin, IoTeX) or a custom Ethereum L2 (Gensyn) ([Akash](https://akash.network/docs/learn/core-concepts/providers-leases/); [Taostats](https://docs.taostats.io/docs/validation); [Filecoin](https://github.com/filecoin-project/filecoin-docs/blob/main/basics/what-is-filecoin/crypto-economics.md); [BlockEden](https://blockeden.xyz/blog/2026/05/05/gensyn-rl-swarm-decentralized-ml-training-ethglobal/)). The split maps cleanly onto whether a protocol needs cheap high-frequency micro-rewards (Solana) versus sovereign control of its own consensus and economics (own L1).
