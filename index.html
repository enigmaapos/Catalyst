<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <title>Catalyst — dApp (Option B V5)</title>
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <script src="https://cdn.jsdelivr.net/npm/ethers@6.9.0/dist/ethers.min.js" integrity="" crossorigin="anonymous"></script>
  <style>
    body { font-family: Inter, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial; margin: 0; padding: 20px; background: #0f172a; color: #e6eef8; }
    .container { max-width: 1000px; margin: 0 auto; }
    header { display:flex; align-items:center; justify-content:space-between; gap:16px; margin-bottom:20px; }
    h1 { margin:0; font-size:20px; color:#fff; }
    .card { background: linear-gradient(180deg, rgba(255,255,255,0.02), rgba(255,255,255,0.01)); border: 1px solid rgba(255,255,255,0.04); padding:16px; border-radius:12px; margin-bottom:16px; }
    label { font-size:13px; color:#cfe6ff; }
    input, select, button, textarea { width:100%; padding:10px; margin-top:6px; border-radius:8px; border:1px solid rgba(255,255,255,0.06); background: rgba(255,255,255,0.02); color:#e6eef8; box-sizing:border-box; }
    .row { display:flex; gap:12px; }
    .col { flex:1; }
    .small { font-size:12px; color:#9fbbe8; margin-top:8px; }
    .grid { display:grid; grid-template-columns: repeat(2, 1fr); gap:12px; }
    pre { background: rgba(0,0,0,0.2); padding:8px; border-radius:8px; overflow:auto; max-height:200px; }
    button.primary { background:#0ea5a4; border:none; color:#052f2f; font-weight:700; cursor:pointer; }
    button.ghost { background:transparent; border:1px solid rgba(255,255,255,0.06); color:#e6eef8; cursor:pointer; }
    footer { margin-top:24px; color:#8eb4da; font-size:13px; }
    .kbd { background: rgba(255,255,255,0.03); border-radius:6px; padding:3px 6px; font-weight:600; }
    .split { display:flex; gap:12px; align-items:flex-start; }
    .left { flex:2; } .right { flex:1; min-width:260px; }
    .list { max-height:220px; overflow:auto; margin-top:8px; }
    .item { padding:8px; border-bottom:1px dashed rgba(255,255,255,0.02); }
    .muted { color:#7fb0d6; font-size:12px; }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <h1>Catalyst DApp — Option B V5</h1>
      <div>
        <div id="network" class="muted">Not connected</div>
        <div style="margin-top:8px;">
          <button id="connectBtn" class="primary">Connect Wallet</button>
        </div>
      </div>
    </header>

    <div class="split">
      <div class="left">
        <!-- Account Info -->
        <div class="card">
          <h3>Account</h3>
          <div id="accountInfo" class="muted">Not connected</div>
          <div style="display:flex; gap:8px; margin-top:8px;">
            <button id="refreshBtn" class="ghost">Refresh</button>
            <button id="disconnectBtn" class="ghost">Disconnect (reload)</button>
          </div>
        </div>

        <!-- Token Dashboard -->
        <div class="card">
          <h3>CATA Token</h3>
          <div class="grid">
            <div>
              <label>My CATA Balance</label>
              <div id="cataBalance" class="muted">-</div>
            </div>
            <div>
              <label>Contract Treasury Balance (internal)</label>
              <div id="treasuryBalance" class="muted">-</div>
            </div>
          </div>
          <div style="margin-top:12px;">
            <label>Transfer CATA (quick)</label>
            <div class="row" style="margin-top:6px;">
              <input id="transferTo" placeholder="recipient address" />
              <input id="transferAmount" placeholder="amount (whole tokens)" />
              <button id="transferBtn" class="primary" style="width:120px;">Send</button>
            </div>
            <div class="small">All CATA operations require your wallet approvals & confirmations.</div>
          </div>
        </div>

        <!-- Staking Controls -->
        <div class="card">
          <h3>NFT Staking</h3>

          <div style="margin-bottom:10px;">
            <label>Collection Address</label>
            <input id="collection" placeholder="0x..." />
          </div>

          <div class="row" style="margin-bottom:10px;">
            <div class="col">
              <label>Token ID</label>
              <input id="tokenId" placeholder="1234" />
            </div>
            <div class="col">
              <label>Stake Type</label>
              <select id="stakeType">
                <option value="term">Term Stake (timelocked)</option>
                <option value="permanent">Permanent Stake (pay fee)</option>
              </select>
            </div>
          </div>

          <div style="display:flex; gap:8px;">
            <button id="stakeBtn" class="primary">Stake NFT</button>
            <button id="unstakeBtn" class="ghost">Unstake NFT</button>
            <button id="harvestBtn" class="ghost">Harvest Single</button>
          </div>

          <div style="margin-top:12px;">
            <label>Batch Harvest (tokenIds, comma-separated)</label>
            <input id="batchTokenIds" placeholder="1,2,3" />
            <div style="display:flex; gap:8px; margin-top:8px;">
              <button id="batchHarvestBtn" class="primary">Harvest Batch</button>
            </div>
          </div>

          <div class="small" style="margin-top:8px;">
            For NFT staking the dApp will call the NFT contract's <span class="kbd">safeTransferFrom</span> from your wallet to the staking contract address.
          </div>
        </div>

        <!-- Collection / Admin -->
        <div class="card">
          <h3>Collection Registration & Admin</h3>
          <label>Register Collection (admin)</label>
          <div class="row" style="margin-top:8px;">
            <input id="registerCollectionAddr" placeholder="0xCollectionAddress" />
            <button id="registerCollectionBtn" class="primary">Register</button>
          </div>

          <div style="margin-top:12px;">
            <label>Burn CATA (voluntary)</label>
            <div class="row" style="margin-top:8px;">
              <input id="burnAmount" placeholder="amount (whole tokens)" />
              <input id="burnCollection" placeholder="collection address (optional)" />
              <button id="burnBtn" class="primary">Burn</button>
            </div>
            <div class="small">This executes a voluntary burn that contributes to the leaderboard.</div>
          </div>

          <div style="margin-top:12px;">
            <label>Quarterly Bonus (admin trigger)</label>
            <div class="row" style="margin-top:8px;">
              <button id="distributeBonusBtn" class="primary">Distribute Quarterly Bonus</button>
            </div>
          </div>
        </div>

        <!-- Governance -->
        <div class="card">
          <h3>Governance</h3>
          <div>
            <label>Create Proposal</label>
            <select id="proposalParam">
              <option value="SET_BASE_REWARD_RATE">SET_BASE_REWARD_RATE</option>
              <option value="SET_BONUS_CAP_PERCENT">SET_BONUS_CAP_PERCENT</option>
              <option value="SET_EMISSION_CAP">SET_EMISSION_CAP</option>
              <option value="SET_MINTING_ENABLED">SET_MINTING_ENABLED</option>
              <option value="SET_QUARTERLY_BLOCKS">SET_QUARTERLY_BLOCKS</option>
              <option value="SET_COLLECTION_REGISTRATION_FEE">SET_COLLECTION_REGISTRATION_FEE</option>
              <option value="SET_UNSTAKE_BURN_FEE">SET_UNSTAKE_BURN_FEE</option>
              <option value="SET_PROPOSAL_DURATION_BLOCKS">SET_PROPOSAL_DURATION_BLOCKS</option>
              <option value="SET_QUORUM_VOTES">SET_QUORUM_VOTES</option>
              <option value="SET_MAX_VOTE_WEIGHT">SET_MAX_VOTE_WEIGHT</option>
            </select>
            <input id="proposalValue" placeholder="numeric value" style="margin-top:8px;" />
            <div style="display:flex; gap:8px; margin-top:8px;">
              <button id="createProposalBtn" class="primary">Create</button>
              <button id="voteForBtn" class="ghost">Vote For</button>
              <button id="voteAgainstBtn" class="ghost">Vote Against</button>
              <button id="executeProposalBtn" class="ghost">Execute</button>
            </div>
            <div class="small" style="margin-top:8px;">Enter proposal ID to vote/execute in the prompt when asked.</div>
          </div>
        </div>

      </div>

      <div class="right">
        <!-- Contract & Leaderboard Info -->
        <div class="card">
          <h3>Contract</h3>
          <label>Contract Address</label>
          <div id="contractAddr" class="muted">YOUR_CONTRACT_ADDRESS_HERE</div>
          <div style="margin-top:8px;">
            <label>Registered Collections</label>
            <div id="registeredList" class="list muted">—</div>
          </div>
          <div style="margin-top:8px;">
            <label>Top Burners (Top 10 shown)</label>
            <div id="topList" class="list muted">—</div>
          </div>
        </div>

        <div class="card">
          <h3>Quick Readouts</h3>
          <div class="small">Treasury Balance (internal)</div>
          <div id="tv" class="muted">-</div>
          <div class="small" style="margin-top:8px;">Tracked Count</div>
          <div id="trackedCount" class="muted">-</div>
          <div class="small" style="margin-top:8px;">Last Quarterly Distribution Block</div>
          <div id="lastQuarter" class="muted">-</div>
        </div>

        <div class="card">
          <h3>Logs / Response</h3>
          <pre id="log">Ready.</pre>
        </div>

      </div>
    </div>

    <footer>
      Catalyst — Option B V5 dApp • Test thoroughly on testnet • Replace ABI & contract address with your deployed values before production.
    </footer>
  </div>

<script>
(async function() {
  // ---- CONFIG ----
  const CONTRACT_ADDRESS = "YOUR_CONTRACT_ADDRESS_HERE"; // << REPLACE with deployed contract address
  // Minimal ABI for interacting with the most used functions. Replace with full ABI for full compatibility.
  const CATA_CONTRACT_ABI = [
    // ERC20 reads
    "function balanceOf(address) view returns (uint256)",
    "function transfer(address to, uint256 amount) returns (bool)",
    // Staking methods
    "function termStake(address collectionAddress, uint256 tokenId) external",
    "function permanentStake(address collectionAddress, uint256 tokenId) external",
    "function unstake(address collectionAddress, uint256 tokenId) external",
    "function harvestBatch(address collectionAddress, uint256[] calldata tokenIds) external",
    "function pendingRewards(address collectionAddress, address owner, uint256 tokenId) view returns (uint256)",
    "function burnCATA(uint256 amount, address collectionAddress) external",
    "function setCollectionConfig(address collectionAddress) external",
    // leaderboard & treasury
    "function getTopBurners(uint256 n) view returns (address[] memory, uint256[] memory)",
    "function getRegisteredCollections() view returns (address[] memory)",
    "function getTreasuryBalance() view returns (uint256)",
    "function getTrackedCount() view returns (uint256)",
    "function lastQuarterlyDistributionBlock() view returns (uint256)",
    "function distributeQuarterlyBonus() external",
    // governance
    "function createProposal(uint8 param, uint256 value) external returns (uint256)",
    "function voteOnProposal(uint256 id, bool support) external",
    "function executeProposal(uint256 id) external",
    // helpers (if present)
    "function getBurnedByUser(address) view returns (uint256)",
    // ERC721
    "function onERC721Received(address,address,uint256,bytes) external returns (bytes4)"
  ];

  // helper: ERC721 minimal ABI for safeTransferFrom
  const ERC721_MIN_ABI = [
    "function safeTransferFrom(address from, address to, uint256 tokenId) external",
    "function ownerOf(uint256 tokenId) view returns (address)"
  ];

  // ---- UI elements ----
  const connectBtn = document.getElementById("connectBtn");
  const disconnectBtn = document.getElementById("disconnectBtn");
  const refreshBtn = document.getElementById("refreshBtn");
  const accountInfo = document.getElementById("accountInfo");
  const networkEl = document.getElementById("network");
  const log = document.getElementById("log");
  const contractAddrEl = document.getElementById("contractAddr");
  const cataBalanceEl = document.getElementById("cataBalance");
  const treasuryBalanceEl = document.getElementById("treasuryBalance");
  const transferBtn = document.getElementById("transferBtn");
  const transferTo = document.getElementById("transferTo");
  const transferAmount = document.getElementById("transferAmount");

  const collectionInput = document.getElementById("collection");
  const tokenIdInput = document.getElementById("tokenId");
  const stakeType = document.getElementById("stakeType");
  const stakeBtn = document.getElementById("stakeBtn");
  const unstakeBtn = document.getElementById("unstakeBtn");
  const harvestBtn = document.getElementById("harvestBtn");
  const batchTokenIds = document.getElementById("batchTokenIds");
  const batchHarvestBtn = document.getElementById("batchHarvestBtn");

  const registerCollectionAddr = document.getElementById("registerCollectionAddr");
  const registerCollectionBtn = document.getElementById("registerCollectionBtn");
  const burnAmountInput = document.getElementById("burnAmount");
  const burnCollectionInput = document.getElementById("burnCollection");
  const burnBtn = document.getElementById("burnBtn");
  const distributeBonusBtn = document.getElementById("distributeBonusBtn");

  const proposalParam = document.getElementById("proposalParam");
  const proposalValue = document.getElementById("proposalValue");
  const createProposalBtn = document.getElementById("createProposalBtn");
  const voteForBtn = document.getElementById("voteForBtn");
  const voteAgainstBtn = document.getElementById("voteAgainstBtn");
  const executeProposalBtn = document.getElementById("executeProposalBtn");

  const registeredList = document.getElementById("registeredList");
  const topList = document.getElementById("topList");
  const tv = document.getElementById("tv");
  const trackedCountEl = document.getElementById("trackedCount");
  const lastQuarterEl = document.getElementById("lastQuarter");

  // ---- State ----
  let provider, signer, account;
  let cataContract;

  function logMsg(...args) {
    console.log(...args);
    log.textContent = (new Date()).toISOString() + " — " + args.map(a => (typeof a === "object") ? JSON.stringify(a, null, 2) : String(a)).join(" ");
  }

  // Connect wallet (MetaMask)
  async function connect() {
    try {
      if (!window.ethereum) throw new Error("No injected wallet found (MetaMask)");
      provider = new ethers.BrowserProvider(window.ethereum);
      await provider.send("eth_requestAccounts", []);
      signer = await provider.getSigner();
      account = await signer.getAddress();
      const network = await provider.getNetwork();
      networkEl.textContent = `Connected: ${network.name || network.chainId}`;
      accountInfo.innerHTML = `<div><strong>${account}</strong></div><div class="muted">Signer ready</div>`;
      cataContract = new ethers.Contract(CONTRACT_ADDRESS, CATA_CONTRACT_ABI, signer);
      contractAddrEl.textContent = CONTRACT_ADDRESS;
      connectBtn.textContent = "Connected";
      connectBtn.disabled = true;
      await refreshAll();
    } catch (err) {
      logMsg("connect error", err.message || err);
      alert("Connect error: " + (err.message || err));
    }
  }

  connectBtn.onclick = connect;
  disconnectBtn.onclick = () => location.reload();
  refreshBtn.onclick = () => refreshAll();

  // Refresh UI data
  async function refreshAll() {
    if (!cataContract || !signer) {
      logMsg("Not connected");
      return;
    }
    try {
      // balances
      const bal = await cataContract.balanceOf(account);
      cataBalanceEl.textContent = formatUnits(bal);
      const tBal = await tryCall(cataContract, "getTreasuryBalance");
      treasuryBalanceEl.textContent = tBal ? formatUnits(tBal) : "-";

      // registered collections
      const regs = await tryCall(cataContract, "getRegisteredCollections");
      if (regs) {
        registeredList.innerHTML = regs.length ? regs.map(a => `<div class="item">${a}</div>`).join("") : "<div class='muted'>none</div>";
      }

      // leaderboard (top 10)
      const top = await tryCall(cataContract, "getTopBurners", [10]);
      if (top && top[0]) {
        const addrs = top[0];
        const amounts = top[1];
        topList.innerHTML = "";
        for (let i=0;i<addrs.length;i++) {
          topList.innerHTML += `<div class="item"><strong>#${i+1}</strong> ${addrs[i]} — ${formatUnits(amounts[i])}</div>`;
        }
      } else {
        topList.innerHTML = "<div class='muted'>none</div>";
      }

      const tracked = await tryCall(cataContract, "getTrackedCount");
      trackedCountEl.textContent = tracked ? String(tracked) : "-";

      const lastQ = await tryCall(cataContract, "lastQuarterlyDistributionBlock");
      lastQuarterEl.textContent = lastQ ? String(lastQ) : "-";

      tv.textContent = treasuryBalanceEl.textContent;
      logMsg("refreshed");
    } catch (err) {
      logMsg("refresh error", err.message || err);
    }
  }

  // Helper to call contract methods that may be missing in minimal ABI (try/catch)
  async function tryCall(contract, fname, args=[]) {
    try {
      if (!contract[fname]) {
        // try generic function call
        return await contract.callStatic ? await contract.callStatic[ fname ]?.(...args) : null;
      }
      return await contract[fname](...args);
    } catch (err) {
      // fallback: try provider.getAddress? ignore
      return null;
    }
  }

  // format units (18 decimals)
  function formatUnits(v) {
    try {
      return ethers.formatUnits(v, 18).toString();
    } catch (e) {
      return v ? String(v) : "-";
    }
  }

  // Quick transfer
  transferBtn.onclick = async () => {
    if (!cataContract) return alert("Connect wallet first");
    const to = transferTo.value.trim();
    const amt = transferAmount.value.trim();
    if (!ethers.isAddress(to)) return alert("Invalid address");
    if (!amt) return alert("Enter amount");
    try {
      const parsed = ethers.parseUnits(amt, 18);
      const tx = await cataContract.transfer(to, parsed);
      logMsg("transfer tx sent", tx.hash);
      await tx.wait();
      logMsg("transfer confirmed");
      await refreshAll();
    } catch (err) { logMsg("transfer error", err.message || err); }
  };

  // Stake (calls NFT contract safeTransferFrom from user to staking contract)
  stakeBtn.onclick = async () => {
    if (!signer) return alert("Connect wallet first");
    const coll = collectionInput.value.trim();
    const tid = tokenIdInput.value.trim();
    const type = stakeType.value;
    if (!ethers.isAddress(coll)) return alert("Invalid collection address");
    if (!tid) return alert("Enter token id");

    try {
      // call NFT contract safeTransferFrom(from, contractAddress, tokenId)
      const nft = new ethers.Contract(coll, ERC721_MIN_ABI, signer);
      // Need to transfer NFT to contract; for permanent stake we still transfer NFT and then call permanentStake on contract to account for fee.
      // Option B contract expects NFT.safeTransferFrom(user, address(this), tokenId) so we do that.
      // IMPORTANT: After transfer, we must call the staking contract function (termStake or permanentStake) to register — in our contract code termStake expects the contract to have received NFT via safeTransferFrom; however in solidity we used safeTransferFrom inside the staking functions themselves. Since in Option B we wrote staking functions that themselves call IERC721.safeTransferFrom(_msgSender(), address(this), tokenId)
      // In practice, the staking contract triggers the NFT transfer inside termStake/permanentStake, so dApp should call stakingContract.termStake(...) directly (not transfer NFT first).
      // We'll call the staking contract method (termStake or permanentStake) via signer.

      // Call staking contract directly:
      if (!cataContract[type === "term" ? "termStake" : "permanentStake"]) {
        alert("Contract ABI missing stake function; update ABI to include termStake/permanentStake");
        return;
      }
      const tx = await (type === "term" ? cataContract.termStake(coll, tid) : cataContract.permanentStake(coll, tid));
      logMsg("staking tx sent", tx.hash);
      await tx.wait();
      logMsg("stake confirmed");
      await refreshAll();
    } catch (err) {
      logMsg("stake error", err.message || err);
      alert("Stake failed: " + (err.message || err));
    }
  };

  // Unstake
  unstakeBtn.onclick = async () => {
    if (!cataContract) return alert("Connect wallet first");
    const coll = collectionInput.value.trim();
    const tid = tokenIdInput.value.trim();
    if (!ethers.isAddress(coll)) return alert("Invalid collection");
    if (!tid) return alert("Enter token id");
    try {
      const tx = await cataContract.unstake(coll, tid);
      logMsg("unstake tx", tx.hash);
      await tx.wait();
      logMsg("unstake confirmed");
      await refreshAll();
    } catch (err) { logMsg("unstake error", err.message || err); }
  };

  // Harvest single
  harvestBtn.onclick = async () => {
    if (!cataContract) return alert("Connect wallet first");
    const coll = collectionInput.value.trim();
    const tid = tokenIdInput.value.trim();
    if (!ethers.isAddress(coll)) return alert("Invalid collection");
    if (!tid) return alert("Enter token id");
    try {
      // No dedicated harvest single exists in minimal ABI (but contract has _harvest internal & harvestBatch). If project has harvestAll or harvest function, update ABI and call it.
      // We'll call harvestBatch with single token for compatibility.
      const tx = await cataContract.harvestBatch(coll, [tid]);
      logMsg("harvest tx", tx.hash);
      await tx.wait();
      logMsg("harvest confirmed");
      await refreshAll();
    } catch (err) { logMsg("harvest error", err.message || err); }
  };

  // Harvest batch
  batchHarvestBtn.onclick = async () => {
    if (!cataContract) return alert("Connect wallet first");
    const coll = collectionInput.value.trim();
    const ids = (batchTokenIds.value || "").split(",").map(s => s.trim()).filter(Boolean);
    if (!ethers.isAddress(coll)) return alert("Invalid collection");
    if (!ids.length) return alert("Enter token IDs comma-separated");
    try {
      const parsed = ids.map(i => Number(i));
      const tx = await cataContract.harvestBatch(coll, parsed);
      logMsg("harvest batch tx", tx.hash);
      await tx.wait();
      logMsg("batch harvest confirmed");
      await refreshAll();
    } catch (err) { logMsg("batch harvest err", err.message || err); }
  };

  // Register collection (admin)
  registerCollectionBtn.onclick = async () => {
    if (!cataContract) return alert("Connect wallet first");
    const coll = registerCollectionAddr.value.trim();
    if (!ethers.isAddress(coll)) return alert("Invalid address");
    try {
      const tx = await cataContract.setCollectionConfig(coll);
      logMsg("register tx", tx.hash);
      await tx.wait();
      logMsg("collection registered");
      await refreshAll();
    } catch (err) { logMsg("register error", err.message || err); }
  };

  // Burn tokens (voluntary)
  burnBtn.onclick = async () => {
    if (!cataContract) return alert("Connect wallet first");
    const amt = burnAmountInput.value.trim();
    const coll = burnCollectionInput.value.trim() || "0x0000000000000000000000000000000000000000";
    if (!amt) return alert("Enter amount");
    try {
      const parsed = ethers.parseUnits(amt, 18);
      const tx = await cataContract.burnCATA(parsed, coll);
      logMsg("burn tx", tx.hash);
      await tx.wait();
      logMsg("burn confirmed");
      await refreshAll();
    } catch (err) { logMsg("burn error", err.message || err); }
  };

  // Distribute quarterly bonus (admin)
  distributeBonusBtn.onclick = async () => {
    if (!cataContract) return alert("Connect wallet first");
    if (!confirm("Distribute quarterly bonus? This is admin-only and will attempt to pull from treasury.")) return;
    try {
      const tx = await cataContract.distributeQuarterlyBonus();
      logMsg("distribute tx", tx.hash);
      await tx.wait();
      logMsg("distribution confirmed");
      await refreshAll();
    } catch (err) { logMsg("distribute error", err.message || err); }
  };

  // Governance: create proposal
  createProposalBtn.onclick = async () => {
    if (!cataContract) return alert("Connect wallet first");
    const paramName = proposalParam.value;
    const valueStr = proposalValue.value.trim();
    if (!valueStr) return alert("Enter numeric value");
    // Map string to enum index used in contract. Adjust mapping if contract uses different ordering.
    const map = {
      "SET_BASE_REWARD_RATE": 1,
      "SET_BONUS_CAP_PERCENT": 2,
      "SET_EMISSION_CAP": 3,
      "SET_MINTING_ENABLED": 4,
      "SET_QUARTERLY_BLOCKS": 5,
      "SET_COLLECTION_REGISTRATION_FEE": 6,
      "SET_UNSTAKE_BURN_FEE": 7,
      "SET_PROPOSAL_DURATION_BLOCKS": 8,
      "SET_QUORUM_VOTES": 9,
      "SET_MAX_VOTE_WEIGHT": 10
    };
    const param = map[paramName];
    if (!param) return alert("Unknown param mapping; update dApp mapping to match contract enum order");
    try {
      const tx = await cataContract.createProposal(param, BigInt(valueStr));
      logMsg("createProposal tx", tx.hash);
      await tx.wait();
      logMsg("proposal created");
      await refreshAll();
    } catch (err) { logMsg("create proposal err", err.message || err); }
  };

  // Vote for / against (prompts user for proposal id)
  voteForBtn.onclick = async () => {
    if (!cataContract) return alert("Connect wallet first");
    const id = prompt("Enter proposal ID to vote for:");
    if (id === null) return;
    try {
      const tx = await cataContract.voteOnProposal(BigInt(id), true);
      logMsg("vote for tx", tx.hash);
      await tx.wait();
      logMsg("voted for");
      await refreshAll();
    } catch (err) { logMsg("vote for err", err.message || err); }
  };
  voteAgainstBtn.onclick = async () => {
    if (!cataContract) return alert("Connect wallet first");
    const id = prompt("Enter proposal ID to vote against:");
    if (id === null) return;
    try {
      const tx = await cataContract.voteOnProposal(BigInt(id), false);
      logMsg("vote against tx", tx.hash);
      await tx.wait();
      logMsg("voted against");
      await refreshAll();
    } catch (err) { logMsg("vote against err", err.message || err); }
  };

  // Execute proposal
  executeProposalBtn.onclick = async () => {
    if (!cataContract) return alert("Connect wallet first");
    const id = prompt("Enter proposal ID to execute:");
    if (id === null) return;
    try {
      const tx = await cataContract.executeProposal(BigInt(id));
      logMsg("execute tx", tx.hash);
      await tx.wait();
      logMsg("executed");
      await refreshAll();
    } catch (err) { logMsg("execute err", err.message || err); }
  };

  // handy: refresh on wallet change / network change
  if (window.ethereum) {
    window.ethereum.on("accountsChanged", (accounts) => {
      logMsg("accounts changed", accounts);
      location.reload();
    });
    window.ethereum.on("chainChanged", (chainId) => {
      logMsg("chain changed", chainId);
      location.reload();
    });
  }

  // Auto-prompt to connect
  // (Don't auto-connect — user must click Connect)

  // Initial UI state
  contractAddrEl.textContent = CONTRACT_ADDRESS;
  logMsg("dApp ready — update CONTRACT_ADDRESS & ABI for full functionality");

})();
</script>

</body>
</html>
