// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

// Inheritance and Libraries
import {Ownable} from "../lib/solady/src/auth/Ownable.sol";
import {Initializable} from "../lib/openzeppelin-contracts-v5/contracts/proxy/utils/Initializable.sol";
import {ERC721Holder} from "../lib/openzeppelin-contracts-v5/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "../lib/openzeppelin-contracts-v5/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IAlignmentVault} from "./IAlignmentVault.sol";
import {EnumerableSet} from "../lib/openzeppelin-contracts-v5/contracts/utils/structs/EnumerableSet.sol";

// Interfaces
import {IWETH9} from "../lib/nftx-protocol-v3/src/uniswap/v3-periphery/interfaces/external/IWETH9.sol";
import {IERC20} from "../lib/openzeppelin-contracts-v5/contracts/interfaces/IERC20.sol";
import {IERC721} from "../lib/openzeppelin-contracts-v5/contracts/interfaces/IERC721.sol";
import {IERC1155} from "../lib/openzeppelin-contracts-v5/contracts/interfaces/IERC1155.sol";
import {INFTXVaultFactoryV3} from "../lib/nftx-protocol-v3/src/interfaces/INFTXVaultFactoryV3.sol";
import {INFTXVaultV3} from "../lib/nftx-protocol-v3/src/interfaces/INFTXVaultV3.sol";
import {INFTXInventoryStakingV3} from "../lib/nftx-protocol-v3/src/interfaces/INFTXInventoryStakingV3.sol";
import {INFTXRouter} from "../lib/nftx-protocol-v3/src/interfaces/INFTXRouter.sol";
import {INonfungiblePositionManager} from "../lib/nftx-protocol-v3/src/uniswap/v3-periphery/interfaces/INonfungiblePositionManager.sol";

// Temporary
import {console2} from "../lib/forge-std/src/console2.sol";

/**
 * @title AlignmentVault
 * @notice This allows anything to send ETH to a vault for the purpose of permanently deepening the floor liquidity of a target NFT collection.
 * While the liquidity is locked forever, the yield can be claimed indefinitely.
 * @dev You must initialize this contract once deployed! There is a factory for this, use it!
 * @author Zodomo.eth (Farcaster/Telegram/Discord/Github: @zodomo, X: @0xZodomo, Email: zodomo@proton.me)
 * @custom:github https://github.com/Zodomo/AlignmentVault
 * @custom:miyamaker https://miyamaker.com
 */
contract AlignmentVault is Ownable, Initializable, ERC721Holder, ERC1155Holder, IAlignmentVault {
    using EnumerableSet for EnumerableSet.UintSet;

    uint256 private constant _NFTX_STANDARD_FEE = 30000000000000000;

    IWETH9 private constant _WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    INFTXVaultFactoryV3 private constant _NFTX_VAULT_FACTORY = INFTXVaultFactoryV3(0xC255335bc5aBd6928063F5788a5E420554858f01);
    INFTXInventoryStakingV3 private constant _NFTX_INVENTORY_STAKING = INFTXInventoryStakingV3(0x889f313e2a3FDC1c9a45bC6020A8a18749CD6152);
    INFTXRouter private constant _NFTX_ROUTER = INFTXRouter(0x70A741A12262d4b5Ff45C0179c783a380EebE42a);
    INonfungiblePositionManager private constant _NFP = INonfungiblePositionManager(0x26387fcA3692FCac1C1e8E4E2B22A6CF0d4b71bF);

    EnumerableSet.UintSet private _childInventoryPositionIds;
    mapping(uint256 tokenId => uint256 amount) private _erc1155Balances;

    uint256 public vaultId;
    uint256 public inventoryPositionId;
    uint256 public liquidityPositionId;
    IERC20 public vault;
    address public alignedNft;
    bool public is1155;

    constructor() payable {}

    function initialize(
        address owner_,
        address alignedNft_,
        uint256 vaultId_
    ) external payable virtual initializer {
        _initializeOwner(owner_);
        alignedNft = alignedNft_;
        bool _is1155;
        if (vaultId_ != 0) {
            try _NFTX_VAULT_FACTORY.vault(vaultId_) returns (address vaultAddr) {
                if (INFTXVaultV3(vaultAddr).assetAddress() != alignedNft_) revert AV_NFTX_InvalidVaultNft();
                if (INFTXVaultV3(vaultAddr).is1155()) {
                    _is1155 = true;
                    is1155 = true;
                }
                vaultId = vaultId_;
                vault = IERC20(vaultAddr);
                emit AV_VaultInitialized(vaultAddr, vaultId_);
            } catch {
                revert AV_NFTX_InvalidVaultId();
            }
        } else {
            address[] memory vaults = _NFTX_VAULT_FACTORY.vaultsForAsset(alignedNft_);
            if (vaults.length == 0) revert AV_NFTX_NoVaultsExist();
            for (uint256 i; i < vaults.length; ++i) {
                (uint256 mintFee, uint256 redeemFee, uint256 swapFee) = INFTXVaultV3(vaults[i]).vaultFees();
                if (mintFee != _NFTX_STANDARD_FEE || redeemFee != _NFTX_STANDARD_FEE || swapFee != _NFTX_STANDARD_FEE) continue;
                else if (INFTXVaultV3(vaults[i]).manager() != address(0)) continue;
                else {
                    if (INFTXVaultV3(vaults[i]).is1155()) {
                        _is1155 = true;
                        is1155 = true;
                    }
                    vaultId_ = INFTXVaultV3(vaults[i]).vaultId();
                    vaultId = vaultId_;
                    vault = IERC20(vaults[i]);
                    emit AV_VaultInitialized(vaults[i], vaultId_);
                    break;
                }
            }
            if (vaultId_ == 0) revert AV_NFTX_NoStandardVault();
        }
        if (!_is1155) {
            IERC721(alignedNft_).setApprovalForAll(address(_NFTX_INVENTORY_STAKING), true);
            IERC721(alignedNft_).setApprovalForAll(address(_NFTX_ROUTER), true);
            IERC721(alignedNft_).setApprovalForAll(address(_NFP), true);
        } else {
            IERC1155(alignedNft_).setApprovalForAll(address(_NFTX_INVENTORY_STAKING), true);
            IERC1155(alignedNft_).setApprovalForAll(address(_NFTX_ROUTER), true);
            IERC1155(alignedNft_).setApprovalForAll(address(_NFP), true);
        }
        vault.approve(address(_NFTX_INVENTORY_STAKING), type(uint256).max);
        vault.approve(address(_NFTX_ROUTER), type(uint256).max);
        vault.approve(address(_NFP), type(uint256).max);
    }

    function disableInitializers() external payable virtual override {
        _disableInitializers();
    }

    function renounceOwnership() public payable virtual override(Ownable, IAlignmentVault) {}

    function getChildInventoryPositionIds() external view virtual returns (uint256[] memory childPositionIds) {
        childPositionIds = _childInventoryPositionIds.values();
    }

    function getSpecificInventoryPositionFees(uint256 positionId_) external view virtual returns (uint256 balance) {
        balance = _NFTX_INVENTORY_STAKING.wethBalance(positionId_);
    }

    function getTotalInventoryPositionFees() external view virtual returns (uint256 balance) {
        unchecked {
            if (inventoryPositionId != 0) balance += _NFTX_INVENTORY_STAKING.wethBalance(inventoryPositionId);
        }
        uint256[] memory childPositionIds = _childInventoryPositionIds.values();
        for (uint256 i; i < childPositionIds.length; ++i) {
            unchecked {
                balance += _NFTX_INVENTORY_STAKING.wethBalance(childPositionIds[i]);
            }
        }
    }

    function getLiquidityPositionFees() external view virtual returns (uint128 token0Fees, uint128 token1Fees) {
        (,,,,,,,,,, token0Fees, token1Fees) = _NFP.positions(liquidityPositionId);
    }

    function inventoryVTokenDeposit(uint256 vTokenAmount) external payable virtual onlyOwner {
        uint256 _positionId = _NFTX_INVENTORY_STAKING.deposit(
            vaultId,
            vTokenAmount,
            address(this),
            "",
            false,
            true
        );
        if (inventoryPositionId == 0) inventoryPositionId = _positionId;
        else _childInventoryPositionIds.add(_positionId);
    }

    function inventoryNftDeposit(uint256[] calldata tokenIds, uint256[] calldata amounts) external payable virtual onlyOwner {
        uint256 _positionId = _NFTX_INVENTORY_STAKING.depositWithNFT(vaultId, tokenIds, amounts, address(this));
        if (inventoryPositionId == 0) inventoryPositionId = _positionId;
        else _childInventoryPositionIds.add(_positionId);
    }

    function inventoryPositionIncrease(uint256 vTokenAmount) external payable virtual onlyOwner {
        uint256 _positionId = inventoryPositionId;
        if (_positionId == 0) revert AV_NoPosition();
        _NFTX_INVENTORY_STAKING.increasePosition(_positionId, vTokenAmount, "", false, true);
    }

    // TODO: Make vTokenPremiumLimit more user-friendly
    function inventoryPositionWithdrawal(uint256 positionId_, uint256 vTokenAmount, uint256[] calldata tokenIds, uint256 vTokenPremiumLimit) external payable virtual onlyOwner {
        _NFTX_INVENTORY_STAKING.withdraw(positionId_, vTokenAmount, tokenIds, vTokenPremiumLimit);
    }

    function inventoryCombinePositions(uint256[] calldata childPositionIds) external payable virtual onlyOwner {
        _NFTX_INVENTORY_STAKING.combinePositions(inventoryPositionId, childPositionIds);
    }

    function inventoryPositionCollectFees(uint256[] calldata positionIds) external payable virtual onlyOwner {
        _NFTX_INVENTORY_STAKING.collectWethFees(positionIds);
    }

    function inventoryPositionCollectAllFees() external payable virtual onlyOwner {
        uint256 _inventoryPositionId = inventoryPositionId;
        uint256[] memory childPositionIds = _childInventoryPositionIds.values();
        uint256 positionCount;
        unchecked {
            if (_inventoryPositionId != 0) ++positionCount;
            positionCount += childPositionIds.length;
        }
        uint256[] memory positionIds = new uint256[](positionCount);
        if (_inventoryPositionId != 0) positionIds[0] = _inventoryPositionId;
        for (uint256 i = 1; i < positionCount; ++i) {
            positionIds[i] = childPositionIds[i - 1];
        }
        _NFTX_INVENTORY_STAKING.collectWethFees(positionIds);
    }

    // TODO: Iron out exact details for how a position can be created and what the limitations are
    function liquidityPositionCreate(uint256 vTokenAmount, uint256 ethAmount, uint256[] calldata tokenIds, uint256[] calldata amounts) external payable virtual onlyOwner {
        if (liquidityPositionId != 0) revert AV_PositionExists();
        INFTXRouter.AddLiquidityParams memory params = INFTXRouter.AddLiquidityParams({
            vaultId: vaultId,
            vTokensAmount: vTokenAmount,
            nftIds: tokenIds,
            nftAmounts: amounts,
            tickLower: 0, // TODO: Get correct value
            tickUpper: 1000000, // TODO: Get correct value
            fee: 3000,
            sqrtPriceX96: 23875693892574983, // TODO: Get correct value,
            vTokenMin: 0,
            wethMin: 0,
            deadline: block.timestamp,
            forceTimelock: true,
            recipient: address(this)
        });
        _NFTX_ROUTER.addLiquidity{value: ethAmount}(params);
    }

    // TODO: Iron out exact details for how a position can be increased and what the limitations are
    function liquidityPositionIncrease(uint256 vTokenAmount, uint256 ethAmount, uint256[] calldata tokenIds, uint256[] calldata amounts) external payable virtual onlyOwner {
        if (liquidityPositionId == 0) revert AV_PositionExists();
        INFTXRouter.IncreaseLiquidityParams memory params = INFTXRouter.IncreaseLiquidityParams({
            positionId: liquidityPositionId,
            vaultId: vaultId,
            vTokensAmount: vTokenAmount,
            nftIds: tokenIds,
            nftAmounts: amounts,
            vTokenMin: 0,
            wethMin: 0,
            deadline: block.timestamp,
            forceTimelock: true
        });
        _NFTX_ROUTER.increaseLiquidity{value: ethAmount}(params);
    }

    function liquidityPositionCollectFees() external payable virtual onlyOwner {
        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: liquidityPositionId,
            recipient: msg.sender,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        _NFP.collect(params);
    }

    // TODO: Figure out if NFTXRouter or MarketplaceUniversalRouterZap is the correct contract to use for this
    function buyNftFromPool(uint256 ethAmount, uint256[] calldata tokenIds) external payable virtual onlyOwner {
        INFTXRouter.BuyNFTsParams memory params = INFTXRouter.BuyNFTsParams({
            vaultId: vaultId,
            nftIds: tokenIds,
            vTokenPremiumLimit: type(uint256).max,
            deadline: block.timestamp,
            fee: 3000,
            sqrtPriceLimitX96: type(uint160).max
        });
        _NFTX_ROUTER.buyNFTs{value: ethAmount}(params);
    }

    function rescueERC20(address token, uint256 amount, address recipient) external payable virtual onlyOwner {
        if (token == address(vault) || token == address(_WETH)) revert AV_ProhibitedWithdrawal();
        IERC20(token).transfer(recipient, amount);
    }

    function rescueERC721(address token, uint256 tokenId, address recipient) external payable virtual onlyOwner {
        if (token == alignedNft || token == address(_NFP)) revert AV_ProhibitedWithdrawal();
        IERC721(token).transferFrom(address(this), recipient, tokenId);
    }

    function rescueERC1155(address token, uint256 tokenId, uint256 amount, address recipient) external payable virtual onlyOwner {
        if (token == alignedNft) revert AV_ProhibitedWithdrawal();
        IERC1155(token).safeTransferFrom(address(this), recipient, tokenId, amount, "");
    }

    function rescueERC1155Batch(address token, uint256[] calldata tokenIds, uint256[] calldata amounts, address recipient) external payable virtual onlyOwner {
        if (token == alignedNft) revert AV_ProhibitedWithdrawal();
        IERC1155(token).safeBatchTransferFrom(address(this), recipient, tokenIds, amounts, "");
    }

    function unwrapEth() external payable virtual onlyOwner {
        _WETH.withdraw(_WETH.balanceOf(address(this)));
    }

    receive() external payable virtual {}
    fallback() external payable virtual {}
}