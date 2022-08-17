// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "./interface/IUniswapV2Factory.sol";
import "./interface/IUniswapV2Router02.sol";
import "./Ham.sol";
import "./interface/IHam.sol";
import "./interface/IOnRye.sol";
import "./ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/metatx/MinimalForwarder.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Triflex is
    ERC20Permit,
    Ownable,
    ReentrancyGuard
{
    using Address for address;

    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;

    IHam public ham;

    IOnRye public onRye;

    address public marketingWallet;

    address public immutable developmentWallet = payable(0x12a102A4e51DAdac9499fdAB4D8a6430318D9163);

    uint256 public constant DECIMALS = 10**18;

    uint256 public constant TOTAL_SUPPLY = 10**9 * DECIMALS; //1 billion

    mapping(address => bool) public rewardAddressWhitelisted;

    mapping(address => bool) public _canTransferBeforeOpenTrading;

    mapping(address => bool) public maxWalletExcluded;

    uint256 public maxWalletAmount;

    // Sell Fees
    uint256 public _sellLiquidityFee; // 9%
    uint256 public _sellMarketingFee; // 2%
    uint256 public _sellDevelopmentFee; // 2%
    uint256 public _sellRewardsToHolders; // 5%

    // Sell Total
    uint256 public sellTotalFee;

    //buy total
    uint256 public buyTotalFee;

    // Thresholds
    uint256 public thresholdPercent;
    uint256 public thresholdDivisor;

    // Admin Flags
    bool public tradingOpen;
    bool public antiBotMode;

    bool private inSwap;

    uint256 public launchedAt;
    uint256 private deadBlocks;

    mapping(address => bool) private _isExcludedFromFee;
    mapping(address => bool) private _isSniper;

    // Events
    event OpenTrading(uint256 launchedAt, bool tradingOpen);
    event RewardsTokenChosen(address user, address rewardsToken);
    event SetAutomatedMarketMakerPair(address newPair);
    event ExcludeFromRewards(address acount);
    event SetTaxBuy(uint256 buyTotalFee);
    event SetTaxSell(uint256 _sellLiquidityFee, uint256 _sellMarketingFee, uint256 _sellDevelopmentFee, uint256 _sellRewardsToHolders);
    event UpdateClaimWait(uint256 newTime);
    event SetNewRouter(address newRouter);
    event ExcludeFromFees(address account, bool isExcluded);
    event ManageSnipers(address[] indexed accounts, bool state);
    event SetWallet(address newWallet);
    event SetSwapThreshold(
        uint256 indexed newpercent,
        uint256 indexed newDivisor
    );
    event MaxWalletExcluded(address wallet, bool isExcluded);
    event MaxWalletAmount(uint256 amount);
    event CanTransferBeforeOpenTrading(address user, bool isAllowed);
    event OnRyeSet(address payable onRye);
    event HamSet(address ham);
    event BNBWithdrawn(address to, uint256 amount);
    event RewardTokenRemoved(address rewardTokenAddress);

    modifier swapping(){
        inSwap = true;
        _;
        inSwap = false;
    }

    constructor (address payable _marketingWallet) ERC20("Triflex Token", "TRFX") ERC20Permit("Triflex Token") {
        require(_marketingWallet != address(0), "Triflex: No null address");

        marketingWallet = payable(_marketingWallet);

        _sellLiquidityFee = 90; // 9%
        _sellMarketingFee = 20; // 2%
        _sellDevelopmentFee = 20; // 2%
        _sellRewardsToHolders = 50; //5%

        buyTotalFee = 180; //18%

        sellTotalFee = _sellLiquidityFee + _sellMarketingFee + _sellDevelopmentFee + _sellRewardsToHolders;

        thresholdPercent = 20;
        thresholdDivisor = 1000;

        antiBotMode = true;

        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(
            0x10ED43C718714eb63d5aA57B78B54704E256024E
        );
        uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(_uniswapV2Router.WETH(), address(this));

        uniswapV2Router = _uniswapV2Router;

        excludeFromFees(_msgSender(), true);
        excludeFromFees(address(this), true);

        _canTransferBeforeOpenTrading[address(this)] = true;
        _canTransferBeforeOpenTrading[_msgSender()] = true;

        maxWalletAmount = (TOTAL_SUPPLY * 21) / 10000; //.21% of TOTAL_SUPPLY

        maxWalletExcluded[uniswapV2Pair] = true;
        maxWalletExcluded[_msgSender()] = true;
        maxWalletExcluded[address(this)] = true;

        _mint(_msgSender(), TOTAL_SUPPLY);

        emit Transfer(address(0), _msgSender(), TOTAL_SUPPLY);
    }

    function setMaxWalletExcluded(address wallet, bool isExcluded)
        external
        onlyOwner
    {
        maxWalletExcluded[wallet] = isExcluded;
        emit MaxWalletExcluded(wallet, isExcluded);
    }

    function setMaxWalletAmount(uint256 amount) public onlyOwner {
        require(amount > (TOTAL_SUPPLY * 15) / 10000000, "TF: too small");  
        maxWalletAmount = amount;
        emit MaxWalletAmount(amount);
    }

    function setCanTransferBeforeOpenTrading(address user, bool isAllowed)
        external
        onlyOwner
    {
        _canTransferBeforeOpenTrading[user] = isAllowed;
        emit CanTransferBeforeOpenTrading(user, isAllowed);
    }

    function setOnRye(address payable _onRye) external onlyOwner {
        require(_onRye != address(0), "No null address");
        onRye = IOnRye(payable(_onRye));
        emit OnRyeSet(_onRye);
    }

    function setHam(address _ham) external onlyOwner {
        require(_ham != address(0), "No null address");
        ham = IHam(_ham);
        emit HamSet(_ham);
    }

    function toggleAntiBot() public onlyOwner {
        if (antiBotMode) {
            antiBotMode = false;
        } else {
            antiBotMode = true;
        }
    }

    function initializeExclusion() public onlyOwner {
        ham.eFR(address(onRye));
        ham.eFR(uniswapV2Pair);
        ham.eFR(address(this));
        ham.eFR(_msgSender());
        ham.eFR(
            address(0x000000000000000000000000000000000000dEaD)
        );
    }

    function initializeRewardTokens() public onlyOwner {
        addRewardAddress(address(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c), true);//wbtc
        addRewardAddress(address(0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE), true);//wxrp
        addRewardAddress(address(0xC001BBe2B87079294C63EcE98BdD0a88D761434e), true);//evergrow
        addRewardAddress(address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c), true);//wbnb
        addRewardAddress(address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56), true);//busd
        addRewardAddress(address(this), false);//triflex
    }


    function isExcludedFromFees(address account) external view returns (bool) {
        return _isExcludedFromFee[account];
    }

    function claim() external {
        require(tradingOpen, "TF: Trading not open");
        bool processed = ham.pA(payable(_msgSender()), false);
        require(processed, "Unsuccessful claim");
    }

    function curentSwapThreshold() internal view returns (uint256) {
        return (balanceOf(uniswapV2Pair) * thresholdPercent) / thresholdDivisor;
    }

    function transfer(address recipient, uint256 amount)
        public
        override
        returns (bool)
    {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "No null address");
        require(to != address(0), "No null address");
        require(amount > 0, "Amount cannot be zero");
        require(!_isSniper[to] && !_isSniper[from], "NS");
        if (!tradingOpen) {
            require(
                _canTransferBeforeOpenTrading[from] ||
                    _canTransferBeforeOpenTrading[to], 
                    "Cannot transfer"
            );
        }

        if (
            launchedAt > 0 &&
            (launchedAt + 1000) > block.number &&
            !maxWalletExcluded[to]
        ) {
            require(balanceOf(to) + amount <= maxWalletAmount, "Tf: maxW");
        }

        uint256 currenttotalFee;

        if (to == uniswapV2Pair) {
            //sell
            currenttotalFee = sellTotalFee;
        }

        if(from == uniswapV2Pair) {
            //buy
            currenttotalFee = buyTotalFee;
        }

        //antibot - first X blocks
        if (launchedAt > 0 && (launchedAt + deadBlocks) > block.number) {
            _isSniper[to] = true;
        }

        //high slippage bot txns
        if (
            launchedAt > 0 &&
            from != owner() &&
            block.number <= (launchedAt + deadBlocks) &&
            antiBotMode
        ) {
            currenttotalFee = 950; //95%
        }

        if (
            _isExcludedFromFee[from] ||
            _isExcludedFromFee[to] ||
            from == owner()
        ) {
            //privileged
            currenttotalFee = 0;
        }
        //sell
        if (!inSwap && tradingOpen && to == uniswapV2Pair && currenttotalFee > 0) {
            //add liquidity before opening trading to this doesn't hit
            uint256 contractTokenBalance = balanceOf(address(this));
            uint256 swapThreshold = curentSwapThreshold();

            if ((contractTokenBalance >= swapThreshold)) {
                swapAndsendEth();
            }
        }
        _transferStandard(from, to, amount, currenttotalFee);
    }

    function _transferStandard(
        address sender,
        address recipient,
        uint256 tAmount,
        uint256 curentTotalFee
    ) private nonReentrant {
        if (curentTotalFee == 0) {
            super._transfer(sender, recipient, tAmount);
        } else {
            uint256 calcualatedFee = (tAmount * curentTotalFee) / (10**3);
            uint256 amountForRecipient = tAmount - calcualatedFee;
            super._transfer(sender, address(this), calcualatedFee); //take tax
            super._transfer(sender, recipient, amountForRecipient);

            // Add to total pending dividends
            uint256 calculatedDividends = (tAmount * _sellRewardsToHolders) / (10**3);
            uint256 currentDividends = onRye
                .gTDD();
            onRye.sTPD(
                currentDividends + calculatedDividends
            );
        }
        //update tracker values
        try
            ham.sb(payable(sender), balanceOf(sender))
        {} catch {}
        try
            ham.sb(payable(recipient), balanceOf(recipient))
        {} catch {}
    }

    function swapAndsendEth() private swapping {
        uint256 amountToLiquify;
        if (_sellLiquidityFee > 0) {
            amountToLiquify = (curentSwapThreshold() * _sellLiquidityFee) / sellTotalFee / 2;
            swapTokensForEth(amountToLiquify);
        }

        uint256 amountETH = address(this).balance;

        if (sellTotalFee > 0) {
            uint256 totalETHFee = sellTotalFee - (_sellLiquidityFee / 2); 
            uint256 amountETHLiquidity = amountETH * _sellLiquidityFee / sellTotalFee / 2;

            if (amountETH > 0) {
                if(_sellDevelopmentFee > 0){
                    uint256 developmentAllocation = amountETH * _sellDevelopmentFee / totalETHFee;

                    (bool dSuccess, ) = payable(developmentWallet).call{
                        value: developmentAllocation
                    }("");
                    if (dSuccess) {
                        emit Transfer(
                            address(this),
                            developmentWallet,
                            developmentAllocation
                        );
                    }
                }
                
                if(_sellMarketingFee > 0){
                    uint256 marketingAllocation = amountETH * _sellMarketingFee / totalETHFee;

                    (bool mSuccess, ) = payable(marketingWallet).call{
                        value: marketingAllocation
                    }("");
                    if (mSuccess) {
                        emit Transfer(
                            address(this),
                            marketingWallet,
                            marketingAllocation
                        );
                    }
                }

                if(_sellRewardsToHolders > 0){
                    uint256 rewardETHAllocation = amountETH * _sellRewardsToHolders / totalETHFee;

                    (bool rSuccess, ) = payable(onRye).call{
                        value: rewardETHAllocation
                    }("");
                    if (rSuccess) {
                        emit Transfer(
                            address(this),
                            address(onRye),
                            rewardETHAllocation
                        );
                    }
                }
            }
            if (amountToLiquify > 0) {
                addLiquidity(amountToLiquify, amountETHLiquidity);
            }
        } else {
            if (amountETH > 0) {
                (bool mSuccess, ) = address(marketingWallet).call{
                    value: amountETH
                }("");
                if (mSuccess) {
                    emit Transfer(address(this), marketingWallet, amountETH);
                }
            }
        }
    }

    function swapTokensForEth(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        super._approve(address(this), address(uniswapV2Router), tokenAmount);

        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            1,
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        super._approve(address(this), address(uniswapV2Router), tokenAmount);

        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            1,
            1,
            address(this),
            block.timestamp
        );
    }

    function setThreshold(uint256 newPercent, uint256 newDivisor)
        external
        onlyOwner
    {
        require(newDivisor > 0 && newPercent > 0, "TF: must be < 0");
        thresholdPercent = newPercent;
        thresholdDivisor = newDivisor;
        emit SetSwapThreshold(thresholdPercent, thresholdDivisor);
    }

    function setWallet(address newMarketingWallet) external onlyOwner {
        require(newMarketingWallet != address(0), "TF: no null addres");
        marketingWallet = newMarketingWallet;
        emit SetWallet(marketingWallet);
    }

    function openTrading(bool state, uint256 _deadBlocks) external onlyOwner {
        tradingOpen = state;
        if (tradingOpen && launchedAt == 0) {
            launchedAt = block.number;
            deadBlocks = _deadBlocks + 22;
        }
        emit OpenTrading(launchedAt, tradingOpen);
    }

    function setAutomatedMarketMakerPair(address newPair) external onlyOwner nonReentrant {
        require(newPair != address(0), "TF: no null address");
        require(newPair != uniswapV2Pair, "Tf: Same Pair");
        ham.eFR(newPair);
        uniswapV2Pair = newPair;
        emit SetAutomatedMarketMakerPair(uniswapV2Pair);
    }

    function setNewRouter(address newRouter) external onlyOwner nonReentrant {
        require(newRouter != address(0), "No null address");
        IUniswapV2Router02 _newRouter = IUniswapV2Router02(newRouter);
        address getPair = IUniswapV2Factory(_newRouter.factory()).getPair(
            address(this),
            _newRouter.WETH()
        );
        if (getPair == address(0)) {
            uniswapV2Pair = IUniswapV2Factory(_newRouter.factory()).createPair(
                address(this),
                _newRouter.WETH()
            );
        } else {
            uniswapV2Pair = getPair;
        }
        uniswapV2Router = _newRouter;
        emit SetNewRouter(newRouter);
    }

    function excludeFromFees(address account, bool isExcluded) public onlyOwner {
        require(account != address(0), "No null address");
        _isExcludedFromFee[account] = isExcluded;
        emit ExcludeFromFees(account, isExcluded);
    }

    function manageSnipers(address[] memory accounts, bool state)
        external
        onlyOwner
    {
        for (uint256 i; i < accounts.length; ++i) {
            _isSniper[accounts[i]] = state;
        }
        emit ManageSnipers(accounts, state);
    }

    function updateClaimWait(uint256 claimWait) external onlyOwner nonReentrant {
        require(claimWait <= 604800, "Tf: shorter");
        ham.uCW(claimWait);
        emit UpdateClaimWait(claimWait);
    }

    function withdrawStuckTokens(IERC20 token, address to) external onlyOwner nonReentrant {
        uint256 balance = token.balanceOf(address(this));
        bool success = token.transfer(to, balance);
        require(success, "Failed");
        emit Transfer(address(this), to, balance);
    }

    function withdrawBNBFromContract(address to) external onlyOwner nonReentrant {
        require(to != address(0), "Tf: No null address");
        require(address(this).balance != 0, "Tf: no BNB");
        uint256 balance = address(this).balance;
        (bool success, ) = to.call{value: balance}("");
        require(success, "Failed");
        emit BNBWithdrawn(to, balance);
    }

    function setTaxesSell(
        uint256 _liquidityFee,
        uint256 _marketingFee,
        uint256 _developmentFee,
        uint256 _rewardsToHolders
    ) external onlyOwner {
        require(
            _liquidityFee + _marketingFee + _developmentFee + _rewardsToHolders <= 500,
            "Tf: Out of bounds"
        );
        _sellLiquidityFee = _liquidityFee;
        _sellMarketingFee = _marketingFee;
        _sellDevelopmentFee = _developmentFee;
        _sellRewardsToHolders = _rewardsToHolders;

        sellTotalFee = _sellLiquidityFee + _sellMarketingFee + _sellDevelopmentFee + _sellRewardsToHolders;

        emit SetTaxSell(_sellLiquidityFee, _sellMarketingFee, _sellDevelopmentFee, _sellRewardsToHolders);
    }

    function setTaxesBuy(
        uint256 _buyTotalFee
    ) external onlyOwner {
        require(
            _buyTotalFee <= 500,
            "Tf: Out of bounds"
        );
        buyTotalFee = _buyTotalFee;
        emit SetTaxBuy(_buyTotalFee);
    }

    function setUserRewardToken(address holder, address rewardTokenAddress)
        external
        nonReentrant
    {
        require(
            rewardTokenAddress.isContract() && rewardTokenAddress != address(0),
            "Tf: Address is invalid."
        );
        require(
            holder == payable(_msgSender()),
            "Tf: can only set for yourself."
        );
        require(
            rewardAddressWhitelisted[rewardTokenAddress] == true,
            "Tf: not in list"
        );
        onRye.sUCRT(holder, rewardTokenAddress);
        emit RewardsTokenChosen(holder, rewardTokenAddress);
    }

    function addRewardAddress(address rewardTokenAddress, bool shouldSwap)
        public
        onlyOwner
    {
        require(
            rewardTokenAddress.isContract() && rewardTokenAddress != address(0),
            "Tf: Address is invalid."
        );
        require(rewardAddressWhitelisted[rewardTokenAddress] != true, "Tf: already in list");
        rewardAddressWhitelisted[rewardTokenAddress] = true;
        onRye.sTA(rewardTokenAddress, true);
        onRye.sTSS(rewardTokenAddress, shouldSwap);
    }

    function removeRewardAddress(address rewardTokenAddress)
        external
        onlyOwner
        nonReentrant
    {
        require(
            rewardAddressWhitelisted[rewardTokenAddress] == true,
            "Tf: Token not found"
        );
        delete rewardAddressWhitelisted[rewardTokenAddress];
        onRye.dTA(rewardTokenAddress);
        onRye.dTSS(rewardTokenAddress);
        emit RewardTokenRemoved(rewardTokenAddress);
    }

    function excludeFromRewards(address account) external onlyOwner nonReentrant {
        require(account != address(0), "No null address");
        ham.eFR(account);
        emit ExcludeFromRewards(account);
    }

    receive() external payable {}
}
