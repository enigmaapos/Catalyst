import React, { useEffect, useState } from "react";
import { ethers } from "ethers";

// CatalystDashboard.jsx
// Single-file React component (Tailwind CSS) that provides a clean, modern UI
// for the Catalyst staking & governance dashboard. Replace CONTRACT_ADDRESS / ABI with your own.

// Usage notes (in-code):
// - This component assumes Tailwind is available in the project.
// - Install ethers (`npm i ethers`) and optionally web3modal if you prefer a nicer wallet UX.
// - Replace CONTRACT_ADDRESS and CONTRACT_ABI with your deployed contract's address and ABI.

const CONTRACT_ADDRESS = "0xYourContractAddressHere";
const CONTRACT_ABI = [/* insert ABI array here */];

export default function CatalystDashboard() {
  // Wallet state
  const [provider, setProvider] = useState(null);
  const [signer, setSigner] = useState(null);
  const [account, setAccount] = useState(null);

  // On-chain summary stats (important/relevant only)
  const [totalStakedNFTs, setTotalStakedNFTs] = useState("—");
  const [totalStakers, setTotalStakers] = useState("—");
  const [baseRewardRate, setBaseRewardRate] = useState("—");
  const [totalBurned, setTotalBurned] = useState("—");
  const [treasuryBalance, setTreasuryBalance] = useState("—");

  // User-specific
  const [pendingCata, setPendingCata] = useState("0.00");
  const [myStakedCount, setMyStakedCount] = useState(0);
  const [myBurnedTotal, setMyBurnedTotal] = useState(0);

  // Top collections & Top burners
  const [topCollections, setTopCollections] = useState([]);
  const [topBurners, setTopBurners] = useState([]);
  const [bonusCycleCountdown, setBonusCycleCountdown] = useState(null);
  const [nextBonusPoolEstimate, setNextBonusPoolEstimate] = useState("—");

  // Governance: proposals (only top-level info)
  const [proposals, setProposals] = useState([]);

  // UI flags
  const [loading, setLoading] = useState(false);
  const [statusMsg, setStatusMsg] = useState("");

  // connect wallet (simple, no Web3Modal)
  async function connectWallet() {
    if (!window.ethereum) {
      alert("Please install MetaMask or open in a Web3-enabled browser");
      return;
    }
    const p = new ethers.providers.Web3Provider(window.ethereum, "any");
    await p.send("eth_requestAccounts", []);
    const s = p.getSigner();
    const a = await s.getAddress();
    setProvider(p);
    setSigner(s);
    setAccount(a);
  }

  // get contract instance (read-only or signer if available)
  function getContract(readOnly = true) {
    if (!provider) return null;
    const prov = readOnly ? provider : signer || provider;
    return new ethers.Contract(CONTRACT_ADDRESS, CONTRACT_ABI, prov);
  }

  // Load global stats (only the key numbers we want to show)
  async function loadGlobalStats() {
    try {
      setLoading(true);
      const contract = getContract(true);
      if (!contract) return;

      // safe read: surround unknown getters with try/catch so UI still loads
      try {
        const totalStaked = await contract.totalStakedNFTsCount();
        setTotalStakedNFTs(totalStaked.toString());
      } catch {
        setTotalStakedNFTs("—");
      }

      try {
        const baseRate = await contract.baseRewardRate();
        setBaseRewardRate(ethers.utils.formatUnits(baseRate, 0));
      } catch {
        setBaseRewardRate("—");
      }

      try {
        const burned = await contract.balanceOf(contract.treasuryAddress ? await contract.treasuryAddress() : "0x0");
        // fallback: read burnedCatalystByCollection aggregation might be off-chain
        setTreasuryBalance(ethers.utils.formatEther(burned));
      } catch {
        setTreasuryBalance("—");
      }

      // top collections (addresses)
      try {
        const tops = await contract.getTopCollections();
        setTopCollections(tops.slice(0, 10));
      } catch { setTopCollections([]); }

      // top burners & next pool estimate
      try {
        const burners = await contract.getTopBurners();
        setTopBurners(burners.slice(0, 10));
      } catch { setTopBurners([]); }

      // bonus pool estimate - best effort
      try {
        const treasuryAddr = await contract.treasuryAddress();
        const treasuryBal = await provider.getBalance(treasuryAddr);
        // fallback: if CATA treasury balance is a token, front-end will need ERC20 call
        // use ethers.utils.formatEther(treasuryBal) if native ETH
        setNextBonusPoolEstimate(ethers.utils.formatEther(treasuryBal));
      } catch { setNextBonusPoolEstimate("—"); }

    } catch (err) {
      console.error(err);
      setStatusMsg("Failed loading global stats");
    } finally {
      setLoading(false);
    }
  }

  // Load user data
  async function loadUserData() {
    if (!account || !provider) return;
    setLoading(true);
    try {
      const contract = getContract(true);
      // Example: pendingCata call expects collection context & tokenId; we show aggregated or leave as placeholder
      // For UX simplicity, we show user's total pending reward across registered collections if contract exposes a helper
      try {
        const pending = await contract.balanceOf(account); // placeholder: replace with contract.pendingUserRewards(account)
        setPendingCata(ethers.utils.formatEther(pending));
      } catch {
        setPendingCata("0.00");
      }

      // my staked count: iterate registered collections (lightweight) — in real UI, use indexer for performance
      try {
        const regs = await contract.getRegisteredCollections();
        let stakedCount = 0;
        for (let i = 0; i < regs.length; i++) {
          const arr = await contract.stakePortfolioByUser(regs[i], account);
          stakedCount += arr.length;
        }
        setMyStakedCount(stakedCount);
      } catch {
        setMyStakedCount(0);
      }

      // my burned total (tracked on-chain mapping burnedCatalystByAddress)
      try {
        const burned = await contract.burnedCatalystByAddress(account);
        setMyBurnedTotal(ethers.utils.formatEther(burned));
      } catch { setMyBurnedTotal(0); }

    } catch (err) {
      console.error(err);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    loadGlobalStats();
    // poll or subscribe to events as needed
    const iv = setInterval(loadGlobalStats, 30000);
    return () => clearInterval(iv);
  }, [provider]);

  useEffect(() => {
    if (account) loadUserData();
  }, [account]);

  // Minimal actions: connect wallet, propose (stub), vote (stub), claim rewards (stub)
  async function handleHarvestAll() {
    if (!signer) return alert("Connect wallet first");
    setStatusMsg("Harvesting... (this will open your wallet)");
    try {
      const contract = getContract(false);
      // Example: contract.harvestAll(collection) or similar — adapt to your ABI
      // await contract.harvestAll(someCollectionAddress);
      setStatusMsg("Harvest tx submitted — check wallet");
    } catch (err) {
      console.error(err);
      setStatusMsg("Harvest failed");
    }
  }

  // Lightweight components for the dashboard (UI only)
  return (
    <div className="min-h-screen bg-gradient-to-br from-gray-900 via-gray-800 to-gray-900 text-gray-200 p-6">
      <header className="max-w-6xl mx-auto flex items-center justify-between mb-6">
        <div className="flex items-center gap-4">
          <div className="w-12 h-12 bg-gradient-to-br from-indigo-500 to-pink-500 rounded-full flex items-center justify-center font-bold">C</div>
          <div>
            <h1 className="text-2xl font-semibold">Catalyst</h1>
            <p className="text-sm text-gray-400">Universal NFT staking & governance — CATA</p>
          </div>
        </div>

        <div className="flex items-center gap-3">
          {account ? (
            <div className="flex items-center gap-3">
              <div className="text-sm text-gray-300">{account.substring(0,6)}...{account.substring(account.length-4)}</div>
              <button className="px-3 py-1 rounded bg-indigo-600 hover:bg-indigo-500 text-sm" onClick={() => { setProvider(null); setSigner(null); setAccount(null); }}>Disconnect</button>
            </div>
          ) : (
            <button className="px-4 py-2 rounded bg-green-500 hover:bg-green-400 text-sm font-semibold" onClick={connectWallet}>Connect Wallet</button>
          )}
        </div>
      </header>

      <main className="max-w-6xl mx-auto grid grid-cols-12 gap-6">
        {/* Left column: Key stats & user */}
        <section className="col-span-8 space-y-6">
          <div className="grid grid-cols-3 gap-4">
            <StatCard title="Total Staked NFTs" value={totalStakedNFTs} />
            <StatCard title="Total Stakers" value={totalStakers} />
            <StatCard title="Base Reward Rate" value={baseRewardRate} />
          </div>

          <div className="bg-gray-850 p-4 rounded-lg">
            <h2 className="text-lg font-semibold mb-3">My Rewards & Activity</h2>
            <div className="grid grid-cols-3 gap-4">
              <MiniCard label="Pending CATA" value={pendingCata} />
              <MiniCard label="My Staked NFTs" value={myStakedCount} />
              <MiniCard label="My Burned CATA" value={myBurnedTotal} />
            </div>

            <div className="mt-4 flex gap-3">
              <button className="px-4 py-2 rounded bg-indigo-600 hover:bg-indigo-500" onClick={handleHarvestAll}>Harvest All</button>
              <button className="px-4 py-2 rounded border border-gray-700" onClick={() => alert('Open Burn modal (UI)')}>Burn CATA</button>
              <button className="px-4 py-2 rounded border border-gray-700" onClick={() => alert('Open Stake modal (UI)')}>Stake NFT</button>
            </div>
          </div>

          <div className="bg-gray-850 p-4 rounded-lg">
            <h2 className="text-lg font-semibold mb-3">Registered Collections (Quick View)</h2>
            <div className="grid grid-cols-2 gap-3 max-h-48 overflow-auto">
              {topCollections.length === 0 ? (
                <div className="text-sm text-gray-400">No registered collections found.</div>
              ) : (
                topCollections.map((c) => (
                  <div key={c} className="p-3 bg-gray-800 rounded flex items-center justify-between">
                    <div className="text-sm">{c}</div>
                    <div className="text-xs text-gray-400">View</div>
                  </div>
                ))
              )}
            </div>
          </div>

          <div className="bg-gray-850 p-4 rounded-lg">
            <h2 className="text-lg font-semibold mb-3">Governance (Top-level)</h2>
            <div className="space-y-3">
              <div className="text-sm text-gray-400">Proposal queue & quick actions. Click a proposal to view details and vote.</div>
              <div className="grid gap-2 mt-2">
                {proposals.length === 0 ? (
                  <div className="text-sm text-gray-400">No proposals currently.</div>
                ) : (
                  proposals.slice(0,5).map((p, idx) => (
                    <div key={idx} className="p-3 rounded bg-gray-800 flex items-center justify-between">
                      <div>
                        <div className="text-sm font-medium">{p.title || 'Proposal'}</div>
                        <div className="text-xs text-gray-400">Ends in {p.endsIn || '—'}</div>
                      </div>
                      <div className="flex gap-2">
                        <button className="px-3 py-1 rounded bg-green-600">Vote</button>
                        <button className="px-3 py-1 rounded border">View</button>
                      </div>
                    </div>
                  ))
                )}
              </div>
              <div className="mt-3">
                <button className="px-3 py-2 rounded bg-indigo-600">Create Proposal</button>
              </div>
            </div>
          </div>

        </section>

        {/* Right column: Leaderboards, Treasury, Top burners */}
        <aside className="col-span-4 space-y-6">
          <div className="bg-gray-850 p-4 rounded-lg">
            <h3 className="text-lg font-semibold">Treasury</h3>
            <div className="mt-3 text-sm text-gray-300">Balance (estimate): {nextBonusPoolEstimate}</div>
            <div className="mt-3 text-xs text-gray-400">Bonus pool per cycle: {bonusPoolPercentPerCycleBPUI(bonusPoolPercentPerCycleBP())}</div>
          </div>

          <div className="bg-gray-850 p-4 rounded-lg">
            <div className="flex items-center justify-between">
              <h3 className="text-lg font-semibold">Top 1% Burner Leaderboard</h3>
              <div className="text-xs text-gray-400">Cycle ready: {bonusCycleStatusText(lastBonusCycleBlockUI())}</div>
            </div>

            <div className="mt-3 max-h-72 overflow-auto">
              {topBurners.length === 0 ? (
                <div className="text-sm text-gray-400">No burner data available.</div>
              ) : (
                topBurners.slice(0,10).map((a, i) => (
                  <div key={a} className="flex items-center justify-between p-2 rounded hover:bg-gray-800">
                    <div className="text-sm">#{i+1} {a.substring(0,6)}...{a.substring(a.length-4)}</div>
                    <div className="text-xs text-gray-400">burned: —</div>
                  </div>
                ))
              )}
            </div>

            <div className="mt-3 flex gap-2">
              <button className="px-3 py-2 rounded bg-indigo-600" onClick={() => alert('Admin: rebuild top burners (off-chain recommended)')}>Rebuild Top Burners</button>
              <button className="px-3 py-2 rounded border" onClick={() => alert('Admin: distribute bonus (on-chain)')}>Distribute Bonus</button>
            </div>
            <div className="mt-2 text-xs text-gray-400">Only admins can rebuild/distribute. Front-end should show eligibility meters per user.</div>
          </div>

          <div className="bg-gray-850 p-4 rounded-lg">
            <h3 className="text-lg font-semibold">Protocol Health</h3>
            <div className="mt-2 text-sm">Total Burned (all collections): {totalBurned}</div>
            <div className="mt-2 text-sm">Active Collections: {registeredCountUI()}</div>
            <div className="mt-2 text-sm">Total Stakers: {totalStakers}</div>
          </div>

        </aside>
      </main>

      <footer className="max-w-6xl mx-auto mt-10 text-center text-xs text-gray-500">Built for Catalyst — CATA • Replace placeholders with your contract ABI & address to enable blockchain actions.</footer>

      {/* status bar */}
      {statusMsg && (
        <div className="fixed bottom-6 right-6 bg-gray-800 px-4 py-2 rounded">{statusMsg}</div>
      )}
    </div>
  );
}

/* -----------------------
   Reusable small components
   ----------------------- */

function StatCard({ title, value }) {
  return (
    <div className="bg-gray-850 p-4 rounded-lg flex flex-col">
      <div className="text-sm text-gray-400">{title}</div>
      <div className="text-2xl font-semibold mt-2">{value}</div>
    </div>
  );
}

function MiniCard({ label, value }) {
  return (
    <div className="bg-gray-800 p-3 rounded flex items-center justify-between">
      <div className="text-xs text-gray-400">{label}</div>
      <div className="text-sm font-medium">{value}</div>
    </div>
  );
}

/* -----------------------
   Helper UI functions
   ----------------------- */

function bonusCyclePercentToString(bp) {
  return `${(bp / 100).toFixed(2)}%`;
}

// these small functions are for placeholders — the actual values should be derived from contract state
function bonusPoolPercentPerCycleBP() { return 500; } // placeholder
function bonusPoolPercentPerCycleBPUI(bp) { return `${(bp/100).toFixed(2)}% of Treasury`; }
function bonusCycleStatusText(lastBlock) { return lastBlock ? 'Ready' : 'Not ready'; }
function lastBonusCycleBlockUI() { return null; }
function registeredCountUI() { return '—'; }
