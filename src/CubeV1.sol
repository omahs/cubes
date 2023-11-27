// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {EIP712Upgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC721Upgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract CubeV1 is
    Initializable,
    ERC721Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    EIP712Upgradeable
{
    using ECDSA for bytes32;

    error TestCUBE__IsNotSigner();
    error TestCUBE__FeeNotEnough();
    error TestCUBE__SignatureAndCubesInputMismatch();
    error TestCUBE__WithdrawFailed();
    error TestCUBE__NonceAlreadyUsed();

    uint256 internal _nextTokenId;
    uint256 internal questCompletionIdCounter;

    bool public isMintingActive;

    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    bytes32 internal constant STEP_COMPLETION_HASH =
        keccak256("StepCompletionData(bytes32 stepTxHash,uint256 stepChainId)");
    bytes32 internal constant CUBE_DATA_HASH = keccak256(
        "CubeData(uint256 questId,uint256 userId,uint256 completedAt,uint256 nonce,string walletProvider,string tokenURI,string embedOrigin,address toAddress,StepCompletionData[] steps)StepCompletionData(bytes32 stepTxHash,uint256 stepChainId)"
    );

    mapping(uint256 => uint256) internal questIssueNumbers;
    mapping(uint256 => string) internal tokenURIs;
    mapping(address signerAddress => mapping(uint256 nonce => bool isConsumed)) internal nonces;

    enum QuestType {
        QUEST,
        STREAK
    }

    enum Difficulty {
        BEGINNER,
        INTERMEDIATE,
        ADVANCED
    }

    event QuestMetadata(
        uint256 indexed questId, QuestType questType, Difficulty difficulty, string title
    );
    event QuestCommunity(uint256 indexed questId, string communityName);
    event CubeClaim(
        uint256 indexed questId,
        uint256 indexed tokenId,
        uint256 issueNumber,
        uint256 userId,
        uint256 completedAt,
        string walletName,
        string embedOrigin
    );
    event CubeTransaction(uint256 indexed tokenId, bytes32 indexed txHash, uint256 indexed chainId);

    struct CubeData {
        uint256 questId;
        uint256 userId;
        uint256 completedAt;
        uint256 nonce;
        string walletProvider;
        string tokenURI;
        string embedOrigin;
        address toAddress;
        StepCompletionData[] steps;
    }

    struct StepCompletionData {
        bytes32 stepTxHash;
        uint256 stepChainId;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory _name,
        string memory _symbol,
        string memory _signingDomain,
        string memory _signatureVersion
    ) public initializer {
        __ERC721_init(_name, _symbol);
        __EIP712_init(_signingDomain, _signatureVersion);
        __AccessControl_init();
        __UUPSUpgradeable_init();

        // TODO: update these so they're not msg.sender?
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(SIGNER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    function setTokenURI(uint256 _tokenId, string memory newuri) external onlyRole(SIGNER_ROLE) {
        tokenURIs[_tokenId] = newuri;
    }

    function tokenURI(uint256 _tokenId) public view override returns (string memory _tokenURI) {
        return tokenURIs[_tokenId];
    }

    function setIsMintingActive(bool _isMintingActive) external onlyRole(SIGNER_ROLE) {
        isMintingActive = _isMintingActive;
    }

    function initializeQuest(
        uint256 questId,
        string[] memory communities,
        string memory title,
        Difficulty difficulty,
        QuestType questType
    ) external onlyRole(SIGNER_ROLE) {
        for (uint256 i = 0; i < communities.length;) {
            emit QuestCommunity(questId, communities[i]);
            unchecked {
                ++i;
            }
        }

        emit QuestMetadata(questId, questType, difficulty, title);

        delete questIssueNumbers[questId];
    }

    function _mintCube(CubeData calldata cubeInput, bytes calldata signature) internal {
        address signer = _getSigner(cubeInput, signature);
        if (!hasRole(SIGNER_ROLE, signer)) {
            revert TestCUBE__IsNotSigner();
        }

        bool isConsumedNonce = nonces[signer][cubeInput.nonce];
        if (isConsumedNonce) {
            revert TestCUBE__NonceAlreadyUsed();
        }

        uint256 tokenId = _nextTokenId;

        uint256 issueNo = questIssueNumbers[cubeInput.questId];

        for (uint256 i = 0; i < cubeInput.steps.length;) {
            emit CubeTransaction(
                questCompletionIdCounter,
                cubeInput.steps[i].stepTxHash,
                cubeInput.steps[i].stepChainId
            );
            unchecked {
                ++i;
            }
        }

        tokenURIs[tokenId] = cubeInput.tokenURI;
        nonces[signer][cubeInput.nonce] = true;

        unchecked {
            ++questCompletionIdCounter;
            ++questIssueNumbers[cubeInput.questId];
            ++_nextTokenId;
        }

        _safeMint(msg.sender, tokenId);

        emit CubeClaim(
            cubeInput.questId,
            tokenId,
            issueNo,
            cubeInput.userId,
            cubeInput.completedAt,
            cubeInput.walletProvider,
            cubeInput.embedOrigin
        );
    }

    function mintMultipleCubes(CubeData[] calldata cubeInputs, bytes[] calldata signatures)
        external
        payable
    {
        if (cubeInputs.length != signatures.length) {
            revert TestCUBE__SignatureAndCubesInputMismatch();
        }
        uint256 totalFee = 777 * cubeInputs.length;

        if (msg.value < totalFee) {
            revert TestCUBE__FeeNotEnough();
        }

        for (uint256 i = 0; i < cubeInputs.length;) {
            _mintCube(cubeInputs[i], signatures[i]);

            unchecked {
                ++i;
            }
        }
    }

    function withdraw() external onlyRole(DEFAULT_ADMIN_ROLE) {
        (bool success,) = msg.sender.call{value: address(this).balance}("");
        if (!success) {
            revert TestCUBE__WithdrawFailed();
        }
    }

    function _getSigner(CubeData calldata data, bytes calldata signature)
        internal
        view
        returns (address)
    {
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    CUBE_DATA_HASH,
                    data.questId,
                    data.userId,
                    data.completedAt,
                    data.nonce,
                    keccak256(bytes(data.walletProvider)),
                    keccak256(bytes(data.tokenURI)),
                    keccak256(bytes(data.embedOrigin)),
                    data.toAddress,
                    _encodeCompletedSteps(data.steps)
                )
            )
        );

        return digest.recover(signature);
    }

    function _encodeStep(StepCompletionData calldata step) internal pure returns (bytes memory) {
        return abi.encode(STEP_COMPLETION_HASH, step.stepTxHash, step.stepChainId);
    }

    function _encodeCompletedSteps(StepCompletionData[] calldata steps)
        internal
        pure
        returns (bytes32)
    {
        bytes32[] memory encodedSteps = new bytes32[](steps.length);

        // hash each step
        for (uint256 i = 0; i < steps.length; i++) {
            encodedSteps[i] = keccak256(_encodeStep(steps[i]));
        }

        // return hash of the concatenated steps
        return keccak256(abi.encodePacked(encodedSteps));
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    receive() external payable {}
}