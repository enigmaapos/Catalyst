<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>Catalyst NFT Staking Protocol - DApp </title>
<script src="https://cdn.jsdelivr.net/npm/ethers@5.7.2/dist/ethers.min.js"></script>
<style>
  :root{
    --bg:#041021; --card:#081826; --muted:#9aa4b2; --accent:#58a6ff; --good:#2ea043;
    --danger:#e05151; --glass: rgba(255,255,255,0.03)
  }
  body{font-family:Inter,system-ui,Arial; background:var(--bg); color:#e6edf3; margin:0; padding:20px}
  header{padding:14px 20px;background:linear-gradient(90deg,#022032,#05102a);border-radius:10px}
  h1{margin:0;color:var(--accent)}
  main{max-width:1100px;margin:18px auto}
  .card{background:var(--card);border-radius:10px;padding:14px;margin:14px 0;border:1px solid var(--glass)}
  label{display:block;color:var(--muted);font-size:13px;margin-top:10px}
  input,select,textarea{width:100%;padding:8px;border-radius:8px;border:1px solid rgba(255,255,255,0.04);background:#071021;color:#e6edf3}
  button{background:var(--accent);border:0;padding:8px 12px;border-radius:8px;color:#012;cursor:pointer;margin-top:8px}
  button.secondary{background:#2b6ee6;color:#fff}
  .row{display:flex;gap:12px}
  .col{flex:1}
  pre{background:#07101a;padding:10px;border-radius:8px;overflow:auto}
  .muted{color:var(--muted);font-size:13px}
  .small{font-size:13px}
  table{width:100%;border-collapse:collapse}
  th,td{padding:8px;border-bottom:1px solid rgba(255,255,255,0.03);text-align:left;font-size:13px}
  .note{font-size:12px;color:#bcd}
  .success{color:var(--good)}
  .danger{color:var(--danger)}
</style>
</head>
<body>
  <header>
    <h1>🚀 Catalyst NFT Staking Protocol</h1>
    <div class="muted small">Aligned with whitepaper: immutable 90/9/1, verified/unverified, escrow, governance, burner bonus.</div>
  </header>

  <main>
    <!-- Network & contract -->
    <div class="card">
      <h2>Network & Contract</h2>
      <div class="muted small">Replace CONTRACT_ADDRESS & CONTRACT_ABI below with your deployed contract's values before production.</div>

      <label>Contract (placeholder)</label>
      <input id="contractAddress" value="0xCONTRACT_ADDRESS_PLACEHOLDER" />

      <div class="row" style="margin-top:10px">
        <button onclick="connect()">Connect Wallet</button>
        <button class="secondary" onclick="loadContract()">Load Contract</button>
      </div>

      <div id="walletInfo" class="muted" style="margin-top:8px">Not connected</div>
      <div id="contractInfo" class="muted" style="margin-top:6px">Contract not loaded</div>
    </div>

    <!-- Register Collection -->
    <div class="card">
      <h2>Register Collection</h2>
      <div class="muted small">Dynamic fee preview (chain-matched), shows surcharge escrow handling for unverified collections.</div>

      <label>Collection Address</label>
      <input id="regCollection" placeholder="0x..." />

      <label>Declared Supply (max 20,000)</label>
      <input id="regDeclaredSupply" type="number" placeholder="e.g. 10000" />

      <label>Request Tier</label>
      <select id="regTier"><option value="0">UNVERIFIED</option><option value="1">VERIFIED</option></select>

      <div class="row">
        <button onclick="previewRegistrationFee()">Preview Fee</button>
        <button class="secondary" onclick="registerCollection()">Register Collection (pay)</button>
      </div>

      <div id="regPreview" class="muted" style="margin-top:8px"></div>
      <div id="regResult" class="muted" style="margin-top:4px"></div>
    </div>

    <!-- Escrow status & upgrade -->
    <div class="card">
      <h2>Escrow & Upgrade</h2>
      <div class="muted small">Check collection escrow, tier, registrant, eligibility to upgrade (on-chain)</div>
      <label>Collection</label>
      <input id="escCollection" placeholder="0x..." />
      <div class="row">
        <button onclick="showCollectionMeta()">Show Escrow / Tier</button>
        <button class="secondary" onclick="forfeitEscrow()">Admin: Forfeit Escrow</button>
      </div>
      <div id="escrowInfo" class="muted" style="margin-top:8px"></div>
    </div>

    <!-- Staking (single & batch) -->
    <div class="card">
      <h2>Stake NFTs</h2>
      <label>Collection Address</label>
      <input id="stakeCollection" placeholder="0x..." />
      <div class="row" style="margin-top:8px">
        <div class="col">
          <label>Single Token ID</label>
          <input id="stakeTokenId" type="number" />
          <div class="row">
            <button onclick="termStakeSingle()">Term Stake</button>
            <button class="secondary" onclick="permanentStakeSingle()">Permanent Stake</button>
          </div>
        </div>
        <div class="col">
          <label>Batch Token IDs (comma separated, max 50)</label>
          <input id="batchStakeIds" placeholder="e.g. 1,2,3" />
          <div class="row">
            <button onclick="batchTermStake()">Batch Term Stake</button>
            <button class="secondary" onclick="batchPermanentStake()">Batch Permanent Stake</button>
          </div>
        </div>
      </div>
      <div id="stakeLog" class="muted" style="margin-top:8px"></div>
    </div>

    <!-- Unstake / Harvest -->
    <div class="card">
      <h2>Unstake / Harvest</h2>
      <label>Collection Address</label>
      <input id="unstakeCollection" placeholder="0x..." />
      <div class="row">
        <div class="col">
          <label>Single Token ID</label>
          <input id="unstakeTokenId" type="number" />
          <div class="row">
            <button onclick="unstakeSingle()">Unstake</button>
            <button class="secondary" onclick="harvestSingle()">Harvest</button>
          </div>
        </div>
        <div class="col">
          <label>Batch Token IDs</label>
          <input id="batchUnstakeIds" placeholder="e.g. 5,6,7" />
          <div class="row">
            <button onclick="batchUnstake()">Batch Unstake</button>
            <button class="secondary" onclick="batchHarvest()">Batch Harvest</button>
          </div>
        </div>
      </div>
      <div id="unstakeLog" class="muted" style="margin-top:8px"></div>
    </div>

    <!-- Governance -->
    <div class="card">
      <h2>Governance</h2>
      <div class="muted small">Create proposals, vote, and execute. Proposal types reflect on-chain enum.</div>

      <label>Proposal Type</label>
      <select id="proposalType">
        <option value="0">BASE_REWARD</option>
        <option value="1">HARVEST_FEE</option>
        <option value="2">UNSTAKE_FEE</option>
        <option value="3">REGISTRATION_FEE_FALLBACK</option>
        <option value="4">VOTING_PARAM</option>
        <option value="5">TIER_UPGRADE</option>
      </select>

      <label>Param Target (for VOTING_PARAM)</label>
      <input id="paramTarget" type="number" placeholder="e.g. 0" />

      <label>New Value</label>
      <input id="newValue" type="number" />

      <label>Collection Context (optional)</label>
      <input id="proposalCollection" placeholder="0x..." />

      <div class="row">
        <button onclick="createProposal()">Create Proposal</button>
        <button class="secondary" onclick="voteProposal()">Vote</button>
        <button class="secondary" onclick="executeProposal()">Execute</button>
      </div>

      <label>Proposal ID (hex bytes32)</label>
      <input id="proposalId" placeholder="0x..." />
      <div id="govLog" class="muted" style="margin-top:8px"></div>
    </div>

    <!-- Treasury & Burner Bonus -->
    <div class="card">
      <h2>Treasury & Burner Bonus</h2>
      <div class="row">
        <button onclick="showTreasury()">Show Treasury</button>
        <button class="secondary" onclick="attemptDistributeBonus()">Distribute Top-1% Bonus</button>
        <button onclick="checkBonusCycle()">Check Bonus Cycle</button>
      </div>
      <div style="margin-top:8px" id="treasuryLog" class="muted"></div>
    </div>

    <!-- Burner Bonus Eligibility Checker -->
    <div class="card">
      <h2>Burner Bonus Eligibility Checker</h2>
      <div class="muted small">Checks on-chain thresholds + your burned & staked totals across registered collections.</div>
      <div class="row">
        <button onclick="checkEligibility()">Check My Eligibility</button>
        <button class="secondary" onclick="refreshRegisteredCollections()">Refresh Collections</button>
      </div>
      <div id="eligibilityLog" class="muted" style="margin-top:8px"></div>
    </div>

    <!-- Leaderboards -->
    <div class="card">
      <h2>Leaderboards</h2>
      <div class="muted small">If on-chain lists exist, they will be shown. Otherwise placeholder data is displayed.</div>
      <div class="row">
        <div class="col">
          <h3 class="small">Top Burners (on-chain)</h3>
          <table id="tableTopBurners"><thead><tr><th>Wallet</th><th>Burned</th></tr></thead><tbody></tbody></table>
        </div>
        <div class="col">
          <h3 class="small">Top Collections (on-chain)</h3>
          <table id="tableTopCollections"><thead><tr><th>Collection</th><th>Burned</th></tr></thead><tbody></tbody></table>
        </div>
      </div>
    </div>

    <!-- Logs -->
    <div class="card">
      <h2>Activity Log</h2>
      <pre id="logs" style="height:200px"></pre>
    </div>

  </main>

<script>
/* -------------------------------
   CONFIG: Replace before production
   ------------------------------- */
const CONTRACT_ADDRESS = "0xCONTRACT_ADDRESS_PLACEHOLDER"; // <-- put deployed contract here
const CONTRACT_ABI = [
  // Minimal ABI fragments used in the DApp.
  "function registerCollection(address,uint256,uint8) payable",
  "function setCollectionConfig(address,uint256,uint8)",
  "function getCollectionMeta(address) view returns (uint8 tier,address registrant,uint256 surchargeEscrow,uint256 registeredAtBlock,uint256 lastTierProposalBlock)",
  "function getRegisteredCollections() view returns (address[])",
  "function _calculateRegistrationBaseFee(uint256) view returns (uint256)", // if public, optional
  "function termStake(address,uint256) external",
  "function permanentStake(address,uint256) external",
  "function termStakeBatch(address,uint256[]) external",
  "function permanentStakeBatch(address,uint256[]) external",
  "function unstake(address,uint256) external",
  "function harvestBatch(address,uint256[]) external",
  "function propose(uint8,uint8,uint256,address) returns (bytes32)",
  "function vote(bytes32) external",
  "function executeProposal(bytes32) external",
  "function distributeTopBurnersBonus() external",
  "function getTopBurners() view returns (address[])",
  "function getTopCollections() view returns (address[])",
  "function treasuryAddress() view returns (address)",
  "function balanceOf(address) view returns (uint256)",
  "function burnedCatalystByAddress(address) view returns (uint256)",
  "function minBurnToQualifyBonus() view returns (uint256)",
  "function minStakedToQualifyBonus() view returns (uint256)",
  // AccessControl helper
  "function hasRole(bytes32,address) view returns (bool)",
  "function CONTRACT_ADMIN_ROLE() view returns (bytes32)"
];

/* -------------------------------
   UI & state
   ------------------------------- */
let provider, signer, contract;

/* Helper: log */
function log(...args){ const el = document.getElementById('logs'); const line = args.map(a=>typeof a==='object'?JSON.stringify(a,null,2):String(a)).join(' '); el.textContent += line + '\\n'; el.scrollTop = el.scrollHeight; }

/* Wallet connect */
async function connect(){
  if(!window.ethereum) return alert('No injected wallet found (MetaMask etc.)');
  provider = new ethers.providers.Web3Provider(window.ethereum, 'any');
  await provider.send('eth_requestAccounts',[]);
  signer = provider.getSigner();
  const addr = await signer.getAddress();
  document.getElementById('walletInfo').textContent = `Connected: ${addr}`;
  log('Wallet connected', addr);
}

/* Load contract (use signer if connected else provider-only) */
function loadContract(){
  try{
    const p = signer || (provider ? provider : ethers.getDefaultProvider());
    contract = new ethers.Contract(CONTRACT_ADDRESS, CONTRACT_ABI, p);
    document.getElementById('contractAddress').value = CONTRACT_ADDRESS;
    document.getElementById('contractInfo').textContent = 'Contract loaded: ' + CONTRACT_ADDRESS;
    log('Contract loaded', CONTRACT_ADDRESS);
    refreshRegisteredCollections();
    fetchTopLists();
  }catch(e){ log('loadContract err', String(e)); }
}

/* -------------------------------
   Fee curve logic (mirrors contract)
   Note: we also attempt to call on-chain estimator if available.
   ------------------------------- */

const UI_FEE_CONSTS = {
  SMALL_MIN_FEE: 1000n * 10n**18n,
  SMALL_MAX_FEE: 5000n * 10n**18n,
  MED_MIN_FEE: 5000n * 10n**18n,
  MED_MAX_FEE: 10000n * 10n**18n,
  LARGE_MIN_FEE: 10000n * 10n**18n,
  LARGE_MAX_FEE_CAP: 20000n * 10n**18n,
  MAX_STAKE_PER_COLLECTION: 20000
};

function bigintSafe(n){
  try{ return BigInt(n); } catch { return BigInt(0); }
}

function calcRegistrationBaseFeeLocal(declaredSupply){
  // replicate contract logic, produce BigInt wei units
  const ds = Number(declaredSupply);
  if(ds <= 0) throw new Error('declaredSupply >= 1');
  if(ds <= 5000){
    const numerator = BigInt(ds) * (UI_FEE_CONSTS.SMALL_MAX_FEE - UI_FEE_CONSTS.SMALL_MIN_FEE);
    return UI_FEE_CONSTS.SMALL_MIN_FEE + numerator / 5000n;
  } else if(ds <= 10000){
    const numerator = BigInt(ds - 5000) * (UI_FEE_CONSTS.MED_MAX_FEE - UI_FEE_CONSTS.MED_MIN_FEE);
    return UI_FEE_CONSTS.MED_MIN_FEE + numerator / 5000n;
  } else {
    const extra = BigInt(ds - 10000);
    const range = 10000n;
    if(extra >= range) return UI_FEE_CONSTS.LARGE_MAX_FEE_CAP;
    const numerator = extra * (UI_FEE_CONSTS.LARGE_MAX_FEE_CAP - UI_FEE_CONSTS.LARGE_MIN_FEE);
    return UI_FEE_CONSTS.LARGE_MIN_FEE + numerator / range;
  }
}

function computeFeeAndSurchargeLocal(baseFeeBN, tierIndex){
  const unverifiedSurchargeBP = 20000n; // default 2x; if contract has different value, preview will be approximate
  const multBP = (tierIndex === 0 ? unverifiedSurchargeBP : 10000n);
  const total = (baseFeeBN * multBP) / 10000n;
  const surcharge = (multBP > 10000n) ? (total - baseFeeBN) : 0n;
  return { totalFee: total, surcharge };
}

/* Preview registration fee */
async function previewRegistrationFee(){
  try{
    const coll = document.getElementById('regCollection').value.trim();
    const ds = Number(document.getElementById('regDeclaredSupply').value || 0);
    const tierIndex = Number(document.getElementById('regTier').value || 0);
    if(!coll || ds <= 0) return alert('Enter collection address and declared supply');
    // try on-chain estimator first (if contract exposes a public _calculateRegistrationBaseFee)
    let baseFeeBN;
    try{
      if(contract && contract._calculateRegistrationBaseFee){
        baseFeeBN = await contract._calculateRegistrationBaseFee(ds);
        baseFeeBN = bigintSafe(baseFeeBN);
      } else {
        baseFeeBN = calcRegistrationBaseFeeLocal(ds);
      }
    }catch(e){
      log('onchain fee estimator missing or errored; using local curve', String(e));
      baseFeeBN = calcRegistrationBaseFeeLocal(ds);
    }
    const { totalFee, surcharge } = computeFeeAndSurchargeLocal(baseFeeBN, tierIndex);
    const baseEth = ethers.utils.formatUnits(baseFeeBN.toString(), 18);
    const totEth = ethers.utils.formatUnits(totalFee.toString(), 18);
    const sEth = ethers.utils.formatUnits(surcharge.toString(), 18);

    const txt = `Base fee: ${baseEth} CATA — Total (with surcharge if any): ${totEth} CATA — Surcharge: ${sEth} CATA
Immutable split (per whitepaper): 90% Burn | 9% Treasury | 1% Deployer`;
    document.getElementById('regPreview').textContent = txt;
    log('Fee preview', txt);
  }catch(e){ log('preview err', String(e)); }
}

/* Register collection (calls contract.registerCollection) */
async function registerCollection(){
  try{
    if(!contract || !signer) return alert('Connect & load contract first');
    const coll = document.getElementById('regCollection').value.trim();
    const ds = Number(document.getElementById('regDeclaredSupply').value || 0);
    const tierIndex = Number(document.getElementById('regTier').value || 0);
    if(!coll || ds <= 0) return alert('Missing fields');
    // NOTE: contract.registerCollection in our final contract expects CATA token balance payment; this UI assumes contract is ERC20/owned by this contract (CATA is native token)
    const tx = await contract.registerCollection(coll, ds, tierIndex, { gasLimit: 800000 });
    log('register tx', tx.hash);
    document.getElementById('regResult').textContent = 'Transaction sent: ' + tx.hash;
    await tx.wait();
    document.getElementById('regResult').textContent = 'Registration mined: ' + tx.hash;
    refreshRegisteredCollections();
  }catch(e){
    log('register err', String(e));
    alert('Registration failed: ' + (e && e.message ? e.message : String(e)));
  }
}

/* Show collection meta (escrow etc) */
async function showCollectionMeta(){
  try{
    if(!contract) return alert('Load contract first');
    const coll = document.getElementById('escCollection').value.trim();
    if(!coll) return alert('Enter collection');
    const meta = await contract.getCollectionMeta(coll);
    // meta assumed to be (uint8 tier, address registrant, uint256 surchargeEscrow, uint256 registeredAtBlock, uint256 lastTierProposalBlock)
    const tier = Number(meta.tier);
    const registrant = meta.registrant;
    const escrow = ethers.utils.formatUnits(meta.surchargeEscrow.toString(), 18);
    const registeredAt = Number(meta.registeredAtBlock);
    const lastTier = Number(meta.lastTierProposalBlock);
    const msg = `Tier: ${tier===0?'UNVERIFIED':'VERIFIED'} | Registrant: ${registrant}\nEscrow: ${escrow} CATA | Registered block: ${registeredAt} | Last tier proposal block: ${lastTier}`;
    document.getElementById('escrowInfo').textContent = msg;
    log('Collection meta', meta);
  }catch(e){ log('showCollectionMeta err', String(e)); alert('Failed to fetch collection meta'); }
}

/* Admin forfeit escrow */
async function forfeitEscrow(){
  try{
    if(!contract || !signer) return alert('Load & connect');
    const coll = document.getElementById('escCollection').value.trim();
    if(!coll) return alert('Enter collection');
    // call forfeitEscrowIfExpired (admin-only in contract)
    if(!confirm('Admin action: forfeit escrow if expired. Proceed?')) return;
    const tx = await contract.forfeitEscrowIfExpired(coll, { gasLimit: 400000 });
    log('forfeit tx', tx.hash);
    await tx.wait();
    log('forfeit done', tx.hash);
    showCollectionMeta();
  }catch(e){ log('forfeitErr', String(e)); alert('Forfeit failed: ' + (e.message || e)); }
}

/* -------------------------------
   Staking helpers (single & batch)
   ------------------------------- */
function parseIds(input){
  return input.split(',').map(s=>s.trim()).filter(Boolean).map(x=>Number(x));
}

async function termStakeSingle(){
  try{
    if(!contract || !signer) return alert('Load & connect wallet');
    const coll = document.getElementById('stakeCollection').value.trim();
    const id = Number(document.getElementById('stakeTokenId').value || 0);
    if(!coll || !id) return alert('Missing');
    const tx = await contract.termStake(coll, id, { gasLimit: 500000 });
    log('termStake tx', tx.hash);
    await tx.wait();
    log('staked', id);
    document.getElementById('stakeLog').textContent = 'Term staked ' + id;
  }catch(e){ log('termStake err', String(e)); alert('Stake failed: ' + (e.message || e)); }
}

async function permanentStakeSingle(){
  try{
    if(!contract || !signer) return alert('Load & connect wallet');
    const coll = document.getElementById('stakeCollection').value.trim();
    const id = Number(document.getElementById('stakeTokenId').value || 0);
    if(!coll || !id) return alert('Missing');
    const tx = await contract.permanentStake(coll, id, { gasLimit: 600000 });
    log('permStake tx', tx.hash);
    await tx.wait();
    log('permanent staked', id);
    document.getElementById('stakeLog').textContent = 'Permanent staked ' + id;
  }catch(e){ log('permStake err', String(e)); alert('Stake failed: ' + (e.message || e)); }
}

async function batchTermStake(){
  try{
    if(!contract || !signer) return alert('Load & connect wallet');
    const coll = document.getElementById('stakeCollection').value.trim();
    const ids = parseIds(document.getElementById('batchStakeIds').value || '');
    if(!coll || ids.length===0) return alert('Missing');
    for(const id of ids){
      try{
        const tx = await contract.termStake(coll, id, { gasLimit: 400000 });
        log('tx', tx.hash);
        await tx.wait();
        log('staked', id);
      }catch(inner){ log('fail', id, String(inner)); }
    }
    document.getElementById('stakeLog').textContent = 'Batch term stake done';
  }catch(e){ log('batchTermStake err', String(e)); }
}

async function batchPermanentStake(){
  try{
    if(!contract || !signer) return alert('Load & connect wallet');
    const coll = document.getElementById('stakeCollection').value.trim();
    const ids = parseIds(document.getElementById('batchStakeIds').value || '');
    if(!coll || ids.length===0) return alert('Missing');
    for(const id of ids){
      try{
        const tx = await contract.permanentStake(coll, id, { gasLimit: 400000 });
        log('tx', tx.hash);
        await tx.wait();
        log('permanent staked', id);
      }catch(inner){ log('fail perm', id, String(inner)); }
    }
    document.getElementById('stakeLog').textContent = 'Batch permanent stake done';
  }catch(e){ log('batchPermanentStake err', String(e)); }
}

/* Unstake / harvest */
async function unstakeSingle(){
  try{
    if(!contract || !signer) return alert('Load & connect wallet');
    const coll = document.getElementById('unstakeCollection').value.trim();
    const id = Number(document.getElementById('unstakeTokenId').value || 0);
    if(!coll || !id) return alert('Missing');
    const tx = await contract.unstake(coll, id, { gasLimit: 400000 });
    log('unstake tx', tx.hash);
    await tx.wait();
    document.getElementById('unstakeLog').textContent = 'Unstaked ' + id;
  }catch(e){ log('unstake err', String(e)); alert('Unstake failed: ' + (e.message || e)); }
}

async function harvestSingle(){
  try{
    if(!contract || !signer) return alert('Load & connect wallet');
    const coll = document.getElementById('unstakeCollection').value.trim();
    const id = Number(document.getElementById('unstakeTokenId').value || 0);
    if(!coll || !id) return alert('Missing');
    const tx = await contract.harvestBatch(coll, [id], { gasLimit: 300000 });
    log('harvest tx', tx.hash);
    await tx.wait();
    document.getElementById('unstakeLog').textContent = 'Harvested ' + id;
  }catch(e){ log('harvest err', String(e)); alert('Harvest failed: ' + (e.message || e)); }
}

async function batchUnstake(){
  try{
    if(!contract || !signer) return alert('Load & connect wallet');
    const coll = document.getElementById('unstakeCollection').value.trim();
    const ids = parseIds(document.getElementById('batchUnstakeIds').value || '');
    if(!coll || ids.length===0) return alert('Missing');
    for(const id of ids){
      try{ const tx = await contract.unstake(coll, id, { gasLimit: 400000 }); log('tx', tx.hash); await tx.wait(); } catch(inner){ log('fail unstake', id, String(inner)); }
    }
    document.getElementById('unstakeLog').textContent = 'Batch unstake done';
  }catch(e){ log('batchUnstake err', String(e)); }
}

async function batchHarvest(){
  try{
    if(!contract || !signer) return alert('Load & connect wallet');
    const coll = document.getElementById('unstakeCollection').value.trim();
    const ids = parseIds(document.getElementById('batchUnstakeIds').value || '');
    if(!coll || ids.length===0) return alert('Missing');
    const tx = await contract.harvestBatch(coll, ids, { gasLimit: 800000 });
    log('harvestBatch tx', tx.hash);
    await tx.wait();
    document.getElementById('unstakeLog').textContent = 'Batch harvest done';
  }catch(e){ log('batchHarvest err', String(e)); }
}

/* -------------------------------
   Governance UI
   ------------------------------- */
async function createProposal(){
  try{
    if(!contract || !signer) return alert('Load & connect');
    const pType = Number(document.getElementById('proposalType').value);
    const paramTarget = Number(document.getElementById('paramTarget').value || 0);
    const newValue = Number(document.getElementById('newValue').value || 0);
    const ctx = document.getElementById('proposalCollection').value || ethers.constants.AddressZero;
    const tx = await contract.propose(pType, paramTarget, newValue, ctx, { gasLimit: 400000 });
    log('propose tx', tx.hash);
    await tx.wait();
    document.getElementById('govLog').textContent = 'Proposal created';
  }catch(e){ log('createProposal err', String(e)); alert('Proposal failed: ' + (e.message || e)); }
}

async function voteProposal(){
  try{
    if(!contract || !signer) return alert('Load & connect');
    const id = document.getElementById('proposalId').value.trim();
    if(!id) return alert('Enter proposal id (bytes32)');
    const tx = await contract.vote(id, { gasLimit: 200000 });
    log('vote tx', tx.hash);
    await tx.wait();
    document.getElementById('govLog').textContent = 'Voted';
  }catch(e){ log('vote err', String(e)); alert('Vote failed: ' + (e.message || e)); }
}

async function executeProposal(){
  try{
    if(!contract || !signer) return alert('Load & connect');
    const id = document.getElementById('proposalId').value.trim();
    if(!id) return alert('Enter proposal id (bytes32)');
    const tx = await contract.executeProposal(id, { gasLimit: 600000 });
    log('exec tx', tx.hash);
    await tx.wait();
    document.getElementById('govLog').textContent = 'Executed';
  }catch(e){ log('exec err', String(e)); alert('Execute failed: ' + (e.message || e)); }
}

/* -------------------------------
   Treasury & Bonus
   ------------------------------- */
async function showTreasury(){
  try{
    if(!contract) return alert('Load contract');
    const t = await contract.treasuryAddress();
    const bal = await contract.balanceOf(t);
    const balFmt = ethers.utils.formatUnits(bal.toString(), 18);
    document.getElementById('treasuryLog').textContent = `Treasury: ${t} | Balance: ${balFmt} CATA`;
    log('treasury', t, bal.toString());
  }catch(e){ log('treasury err', String(e)); }
}

async function attemptDistributeBonus(){
  try{
    if(!contract || !signer) return alert('Load & connect');
    // check admin role if possible
    let isAdmin = false;
    try{
      const role = await contract.CONTRACT_ADMIN_ROLE();
      isAdmin = await contract.hasRole(role, await signer.getAddress());
    }catch(e){ log('role check failed (non-fatal)'); }
    if(!isAdmin && !confirm('You may not be admin — distribution likely to fail. Continue?') ) return;
    const tx = await contract.distributeTopBurnersBonus({ gasLimit: 700000 });
    log('distribute tx', tx.hash);
    await tx.wait();
    log('distributed');
    showTreasury();
  }catch(e){ log('distribute err', String(e)); alert('Distribution failed: ' + (e.message || e)); }
}

async function checkBonusCycle(){
  try{
    if(!contract) return alert('Load contract');
    const last = await contract.lastBonusCycleBlock();
    const cycle = await contract.bonusCycleLengthBlocks();
    log('bonus cycle last', last.toString(), 'length', cycle.toString());
    alert('Last cycle block: ' + last.toString() + '\\nCycle length (blocks): ' + cycle.toString());
  }catch(e){ log('checkBonusCycle err', String(e)); }
}

/* -------------------------------
   Burner Bonus Eligibility
   ------------------------------- */
let cachedRegisteredCollections = [];

async function refreshRegisteredCollections(){
  try{
    if(!contract) return;
    const arr = await contract.getRegisteredCollections();
    cachedRegisteredCollections = arr;
    log('registered collections refreshed', arr);
    return arr;
  }catch(e){ log('refreshRegisteredCollections err', String(e)); return []; }
}

async function checkEligibility(){
  try{
    if(!contract || !signer) return alert('Load & connect wallet');
    const user = await signer.getAddress();
    // read on-chain thresholds
    let minBurnBN = await contract.minBurnToQualifyBonus().catch(()=>null);
    let minStakedBN = await contract.minStakedToQualifyBonus().catch(()=>null);
    // fallback values if not available
    if(!minBurnBN) minBurnBN = ethers.BigNumber.from('100000000000000000000'); // 100 CATA
    if(!minStakedBN) minStakedBN = ethers.BigNumber.from('1');
    // fetch burned
    const burned = await contract.burnedCatalystByAddress(user);
    // compute staked total across registered collections (use cached list or load)
    if(cachedRegisteredCollections.length === 0) await refreshRegisteredCollections();
    let totalStaked = 0;
    for(const coll of cachedRegisteredCollections){
      try{
        // contract has stakePortfolioByUser? There is getUserStakedTokens in earlier variant but not always exposed.
        // We'll attempt to call getUserStakedTokens(coll, user). If missing, skip collection counting (inform user).
        if(contract.getUserStakedTokens){
          const tokens = await contract.getUserStakedTokens(coll, user);
          totalStaked += tokens.length;
        } else {
          // fallback: try stakePortfolioByUser mapping view? Not available by ABI; skip.
        }
      }catch(e){ /* ignore per-collection errors */ }
    }
    const burnedOk = ethers.BigNumber.from(burned.toString()).gte(minBurnBN);
    const stakedOk = ethers.BigNumber.from(totalStaked).gte(minStakedBN);
    const msgLines = [
      `Wallet: ${user}`,
      `Burned: ${ethers.utils.formatUnits(burned.toString(),18)} CATA (min required: ${ethers.utils.formatUnits(minBurnBN.toString(),18)} )`,
      `Staked NFTs total (across registered collections): ${totalStaked} (min required: ${minStakedBN.toString()})`,
      (burnedOk && stakedOk) ? '✅ You are eligible for the burner bonus.' : '❌ Not eligible yet.'
    ];
    if(!burnedOk) msgLines.push('- Burn more CATA or attribute burns to collections.');
    if(!stakedOk) msgLines.push('- Stake more NFTs in registered collections.');
    document.getElementById('eligibilityLog').textContent = msgLines.join('\\n');
    log('eligibility check', msgLines);
  }catch(e){ log('eligibility err', String(e)); alert('Eligibility check failed: ' + (e.message || e)); }
}

/* -------------------------------
   Leaderboards (on-chain or placeholder)
   ------------------------------- */
async function fetchTopLists(){
  try{
    if(!contract) return;
    // Top burners
    let burners = [];
    try{ burners = await contract.getTopBurners(); } catch(e){ log('getTopBurners missing or empty'); }
    const tb = document.querySelector('#tableTopBurners tbody');
    tb.innerHTML = '';
    if(burners && burners.length>0){
      for(const b of burners){
        // try to get burned amount per address? not always available on list; show address only.
        const burned = await contract.burnedCatalystByAddress(b).catch(()=>ethers.BigNumber.from('0'));
        const val = ethers.utils.formatUnits(burned.toString(),18);
        const tr = `<tr><td>${b}</td><td>${val}</td></tr>`;
        tb.insertAdjacentHTML('beforeend', tr);
      }
    } else {
      // placeholder sample
      tb.insertAdjacentHTML('beforeend', '<tr><td>0x123...abc</td><td>120,000</td></tr>');
      tb.insertAdjacentHTML('beforeend', '<tr><td>0x456...def</td><td>95,500</td></tr>');
      tb.insertAdjacentHTML('beforeend', '<tr><td>0x789...ghi</td><td>80,200</td></tr>');
    }

    // Top collections
    let cols = [];
    try{ cols = await contract.getTopCollections(); } catch(e){ log('getTopCollections missing or empty'); }
    const tc = document.querySelector('#tableTopCollections tbody');
    tc.innerHTML = '';
    if(cols && cols.length>0){
      for(const c of cols){
        const burned = await contract.burnedCatalystByCollection(c).catch(()=>ethers.BigNumber.from('0'));
        const val = ethers.utils.formatUnits(burned.toString(),18);
        const tr = `<tr><td>${c}</td><td>${val}</td></tr>`;
        tc.insertAdjacentHTML('beforeend', tr);
      }
    } else {
      tc.insertAdjacentHTML('beforeend', '<tr><td>BAYC</td><td>500,000</td></tr>');
      tc.insertAdjacentHTML('beforeend', '<tr><td>Azuki</td><td>320,000</td></tr>');
      tc.insertAdjacentHTML('beforeend', '<tr><td>CloneX</td><td>210,000</td></tr>');
    }
  }catch(e){ log('fetchTopLists err', String(e)); }
}

/* -------------------------------
   Init: set contract fields in UI if present
   ------------------------------- */
(function initDefaults(){
  document.getElementById('contractAddress').value = CONTRACT_ADDRESS;
  log('DApp ready. Replace placeholders before mainnet.');
})();
</script>
</body>
</html>
