// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma abicoder v2;

//import "../../node_modules/@openzeppelin/contracts/access/Ownable.sol";
import "../../node_modules/@openzeppelin/contracts/access/AccessControl.sol";
import "./StorageStateCommittee.sol";

import { SafeMath } from "../../node_modules/@openzeppelin/contracts/math/SafeMath.sol";
import { IERC20 } from  "../../node_modules/@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ICandidate } from "../interfaces/ICandidate.sol";
import { ILayer2 } from "../interfaces/ILayer2.sol";
import { IDAOAgendaManager } from "../interfaces/IDAOAgendaManager.sol";
import { LibAgenda } from "../lib/Agenda.sol";
import { ERC165Checker } from "../../node_modules/@openzeppelin/contracts/introspection/ERC165Checker.sol";

contract DAOCommittee is StorageStateCommittee, AccessControl {
    using SafeMath for uint256;
    using LibAgenda for *;
     
    enum ApplyResult { NONE, SUCCESS, NOT_ELECTION, ALREADY_COMMITTEE, SLOT_INVALID, ADDMEMBER_FAIL, LOW_BALANCE }

    struct AgendaCreatingData {
        address[] target;
        uint256 noticePeriodSeconds;
        uint256 votingPeriodSeconds;
        bytes[] functionBytecode;
    }

    //////////////////////////////
    // Events
    //////////////////////////////

    event QuorumChanged(
        uint256 newQuorum
    );

    event AgendaCreated(
        address indexed from,
        uint256 indexed id,
        address[] targets,
        uint256 noticePeriodSeconds,
        uint256 votingPeriodSeconds
    );

    event AgendaVoteCasted(
        address indexed from,
        uint256 indexed id,
        uint voting,
        string comment
    );

    event AgendaExecuted(
        uint256 indexed id,
        address[] target
    );

    event CandidateContractCreated(
        address indexed candidate,
        address indexed candidateContract,
        string memo
    );

    event OperatorRegistered(
        address indexed candidate,
        address indexed candidateContract,
        string memo
    );

    event ChangedMember(
        uint256 indexed slotIndex,
        address prevMember,
        address indexed newMember
    );

    event ChangedSlotMaximum(
        uint256 indexed prevSlotMax,
        uint256 indexed slotMax
    );

    event ClaimedActivityReward(
        address indexed candidate,
        uint256 amount
    );

    modifier onlyOwner() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "DAOCommitteeProxy: msg.sender is not an admin");
        _;
    }

    //////////////////////////////////////////////////////////////////////
    // setters

    function setSeigManager(address _seigManager) public onlyOwner {
        require(_seigManager != address(0), "zero address");
        seigManager = ISeigManager(_seigManager);
    }
     
    function setCandidatesSeigManager(
        address[] calldata candidateContracts,
        address _seigManager
    )
        public
        onlyOwner
    {
        require(_seigManager != address(0), "zero address");
        for (uint256 i = 0; i < candidateContracts.length; i++) {
            ICandidate(candidateContracts[i]).setSeigManager(_seigManager);
        }
    }

    function setCandidatesCommittee(
        address[] calldata candidateContracts,
        address _committee
    )
        public
        onlyOwner
    {
        require(_committee != address(0), "zero address");
        for (uint256 i = 0; i < candidateContracts.length; i++) {
            ICandidate(candidateContracts[i]).setCommittee(_committee);
        }
    }

    function setDaoVault(address _daoVault) public onlyOwner {
        require(_daoVault != address(0), "zero address");
        daoVault = IDAOVault2(_daoVault);
    }

    function setLayer2Registry(address _layer2Registry) public onlyOwner {
        require(_layer2Registry != address(0), "zero address");
        layer2Registry = ILayer2Registry(_layer2Registry);
    }

    function setAgendaManager(address _agendaManager) public onlyOwner {
        require(_agendaManager != address(0), "zero address");
        agendaManager = IDAOAgendaManager(_agendaManager);
    }

    function setCandidateFactory(address _candidateFactory) public onlyOwner {
        require(_candidateFactory != address(0), "zero address");
        candidateFactory = ICandidateFactory(_candidateFactory);
    }

    function setTon(address _ton) public onlyOwner {
        require(_ton != address(0), "zero address");
        ton = _ton;
    }

    function setActivityRewardPerSecond(uint256 _value) public onlyOwner {
        activityRewardPerSecond = _value;
    }

    function increaseMaxMember(
        uint256 _newMaxMember,
        uint256 _quorum
    )
        public
        onlyOwner
    {
        require(maxMember < _newMaxMember, "DAOCommitteeStore: You have to call reduceMemberSlot to decrease");
        emit ChangedSlotMaximum(maxMember, _newMaxMember);
        maxMember = _newMaxMember;
        fillMemberSlot();
        setQuorum(_quorum);
    }

    //////////////////////////////////////////////////////////////////////
    // Managing members

    function createCandidate(string memory _memo)
        public
        validSeigManager
        validLayer2Registry
        validCommitteeL2Factory
    {
        require(!isExistCandidate(msg.sender), "DAOCommittee: candidate already registerd");

        // Candidate
        address candidateContract = candidateFactory.deploy(
            msg.sender,
            false,
            _memo,
            address(this),
            address(seigManager)
        );

        require(
            candidateContract != address(0),
            "DAOCommittee: deployed candidateContract is zero"
        );
        require(
            layer2Registry.registerAndDeployCoinage(candidateContract, address(seigManager)),
            "DAOCommittee: failed to registerAndDeployCoinage"
        );
        require(
            candidateInfos[msg.sender].candidateContract == address(0),
            "DAOCommitteeStore: The candidate already has contract"
        );

        candidateInfos[msg.sender] = CandidateInfo({
            candidateContract: candidateContract,
            memberJoinedTime: 0,
            indexMembers: 0,
            rewardPeriod: 0,
            claimedTimestamp: 0
        });

        candidates.push(msg.sender);
       
        emit CandidateContractCreated(msg.sender, candidateContract, _memo);
    }

    function registerOperator(address _layer2, string memory _memo)
        public
        validSeigManager
        validLayer2Registry
        validCommitteeL2Factory
    {
        _registerOperator(msg.sender, _layer2, _memo);
    }

    function registerOperatorByOwner(address _operator, address _layer2, string memory _memo)
        public
        onlyOwner
        validSeigManager
        validLayer2Registry
        validCommitteeL2Factory
    {
        _registerOperator(_operator, _layer2, _memo);
    }

    function changeMember(
        uint256 _memberIndex
    )
        public
        returns (bool)
    {
        address newMember = ICandidate(msg.sender).candidate();
        CandidateInfo storage candidateInfo = candidateInfos[newMember];
        require(
            ICandidate(msg.sender).isCandidateContract(),
            "DAOCommittee: sender is not a candidate contract"
        );
        require(
            _memberIndex < maxMember,
            "DAOCommittee: index is not available"
        );
        require(
            candidateInfo.candidateContract != address(0),
            "DAOCommittee: The address is not a candidate"
        );
        require(
            candidateInfo.memberJoinedTime == 0,
            "DAOCommittee: already member"
        );
        
        address prevMember = members[_memberIndex];
        address prevMemberContract = candidateContract(prevMember);

        candidateInfo.memberJoinedTime = block.timestamp;
        candidateInfo.indexMembers = _memberIndex;

        members[_memberIndex] = newMember;

        if (prevMember == address(0)) {
            emit ChangedMember(_memberIndex, prevMember, newMember);
            return true;
        }

        require(
            ICandidate(msg.sender).totalStaked() > ICandidate(prevMemberContract).totalStaked(),
            "not enough amount"
        );

        CandidateInfo storage prevCandidateInfo = candidateInfos[prevMember];
        prevCandidateInfo.indexMembers = 0;
        prevCandidateInfo.rewardPeriod = prevCandidateInfo.rewardPeriod.add(block.timestamp.sub(prevCandidateInfo.memberJoinedTime));
        prevCandidateInfo.memberJoinedTime = 0;

        emit ChangedMember(_memberIndex, prevMember, newMember);

        return true;
    }
    
    function retireMember() onlyMemberContract public returns (bool) {
        address candidate = ICandidate(msg.sender).candidate();
        CandidateInfo storage candidateInfo = candidateInfos[candidate];
        members[candidateInfo.indexMembers] = address(0);
        candidateInfo.rewardPeriod = candidateInfo.rewardPeriod.add(block.timestamp.sub(candidateInfo.memberJoinedTime));
        candidateInfo.memberJoinedTime = 0;

        emit ChangedMember(candidateInfo.indexMembers, candidate, address(0));

        candidateInfo.indexMembers = 0;
        return true;
    }

    function reduceMemberSlot(
        uint256 _reducingMemberIndex,
        uint256 _quorum
    )
        public
        onlyOwner
    {
        address reducingMember = members[_reducingMemberIndex];
        CandidateInfo storage reducingCandidate = candidateInfos[reducingMember];

        if (_reducingMemberIndex != members.length - 1) {
            address tailmember = members[members.length - 1];
            CandidateInfo storage tailCandidate = candidateInfos[tailmember];

            tailCandidate.indexMembers = _reducingMemberIndex;
            members[_reducingMemberIndex] = tailmember;
        }
        reducingCandidate.indexMembers = 0;
        reducingCandidate.rewardPeriod = reducingCandidate.rewardPeriod.add(block.timestamp.sub(reducingCandidate.memberJoinedTime));
        reducingCandidate.memberJoinedTime = 0;

        members.pop();
        maxMember = maxMember.sub(1);
        setQuorum(_quorum);

        emit ChangedMember(_reducingMemberIndex, reducingMember, address(0));
        emit ChangedSlotMaximum(maxMember.add(1), maxMember);
    }

    //////////////////////////////////////////////////////////////////////
    // Managing agenda

    function onApprove(
        address owner,
        address spender,
        uint256 tonAmount,
        bytes calldata data
    ) external returns (bool) {
        AgendaCreatingData memory agendaData = _decodeAgendaData(data);

        _createAgenda(
            owner,
            agendaData.target,
            agendaData.noticePeriodSeconds,
            agendaData.votingPeriodSeconds,
            agendaData.functionBytecode
        );

        return true;
    }

    function setQuorum(
        uint256 _quorum
    )
        public
        onlyOwner
        validAgendaManager
    {
        require(_quorum > 0, "DAOCommittee: invalid quorum");
        require(_quorum <= maxMember, "DAOCommittee: quorum exceed max member");
        quorum = _quorum;
        emit QuorumChanged(quorum);
    }

    function setCreateAgendaFees(
        uint256 _fees
    )
        public
        onlyOwner
        validAgendaManager
    {
        agendaManager.setCreateAgendaFees(_fees);
    }

    function setMinimumNoticePeriodSeconds(
        uint256 _minimumNoticePeriod
    )
        public
        onlyOwner
        validAgendaManager
    {
        agendaManager.setMinimumNoticePeriodSeconds(_minimumNoticePeriod);
    }

    function setMinimumVotingPeriodSeconds(
        uint256 _minimumVotingPeriod
    )
        public
        onlyOwner
        validAgendaManager
    {
        agendaManager.setMinimumVotingPeriodSeconds(_minimumVotingPeriod);
    }

    function castVote(
        uint256 _agendaID,
        uint _vote,
        string calldata _comment
    )
        public 
        validAgendaManager
    {
        uint256 requiredVotes = quorum;
        require(requiredVotes > 0, "DAOCommittee: requiredVotes is zero");

        address candidate = ICandidate(msg.sender).candidate();
        
        agendaManager.castVote(
            _agendaID,
            candidate,
            _vote
        );

        (uint256 yes, uint256 no, uint256 abstain) = agendaManager.getVotingCount(_agendaID);

        if (requiredVotes <= yes) {
            // yes
            agendaManager.setResult(_agendaID, LibAgenda.AgendaResult.ACCEPT);
            agendaManager.setStatus(_agendaID, LibAgenda.AgendaStatus.WAITING_EXEC);
        } else if (requiredVotes <= no) {
            // no
            agendaManager.setResult(_agendaID, LibAgenda.AgendaResult.REJECT);
            agendaManager.setStatus(_agendaID, LibAgenda.AgendaStatus.ENDED);
        } else if (requiredVotes <= abstain.add(no) ) {
            // dismiss
            agendaManager.setResult(_agendaID, LibAgenda.AgendaResult.DISMISS);
            agendaManager.setStatus(_agendaID, LibAgenda.AgendaStatus.ENDED);
        }
        
        emit AgendaVoteCasted(msg.sender, _agendaID, _vote, _comment);
    }

    function endAgendaVoting(uint256 _agendaID) public {
        agendaManager.endAgendaVoting(_agendaID);
    }

    function executeAgenda(uint256 _agendaID) public validAgendaManager {
        require(
            agendaManager.canExecuteAgenda(_agendaID),
            "DAOCommittee: can not execute the agenda"
        );
        
        (address[] memory target, bytes[] memory functionBytecode) = agendaManager.getExecutionInfo(_agendaID);
       
        agendaManager.setExecutedAgenda(_agendaID);

        for (uint256 i = 0; i < target.length; i++) {
            (bool success, ) = address(target[i]).call(functionBytecode[i]);
            require(success, "DAOCommittee: Failed to execute the agenda");
        }

        emit AgendaExecuted(_agendaID, target);
    }

    function setAgendaStatus(uint256 _agendaID, uint256 _status, uint256 _result) public onlyOwner {
        agendaManager.setResult(_agendaID, LibAgenda.AgendaResult(_result));
        agendaManager.setStatus(_agendaID, LibAgenda.AgendaStatus(_status));
    }
     
    function updateSeigniorage(address _candidate) public returns (bool) {
        address candidateContract = candidateInfos[_candidate].candidateContract;
        return ICandidate(candidateContract).updateSeigniorage();
    }

    function updateSeigniorages(address[] calldata _candidates) public returns (bool) {
        for (uint256 i = 0; i < _candidates.length; i++) {
            updateSeigniorage(_candidates[i]);
        }
    }

    function claimActivityReward() public {
        CandidateInfo storage info = candidateInfos[msg.sender];
        uint256 amount = getClaimableActivityReward(msg.sender);

        require(amount > 0, "DAOCommittee: you don't have claimable ton");

        daoVault.claimTON(msg.sender, amount);
        info.claimedTimestamp = block.timestamp;
        info.rewardPeriod = 0;

        emit ClaimedActivityReward(msg.sender, amount);
    }

    function _registerOperator(address _operator, address _layer2, string memory _memo)
        internal
        validSeigManager
        validLayer2Registry
        validCommitteeL2Factory
    {
        require(!isExistCandidate(_layer2), "DAOCommittee: candidate already registerd");

        require(
            _layer2 != address(0),
            "DAOCommittee: deployed candidateContract is zero"
        );
        require(
            candidateInfos[_layer2].candidateContract == address(0),
            "DAOCommittee: The candidate already has contract"
        );
        ILayer2 layer2 = ILayer2(_layer2);
        require(
            layer2.isLayer2(),
            "DAOCommittee: invalid layer2 contract"
        );
        require(
            layer2.operator() == _operator,
            "DAOCommittee: invalid operator"
        );

        address candidateContract = candidateFactory.deploy(
            _layer2,
            true,
            _memo,
            address(this),
            address(seigManager)
        );

        require(
            candidateContract != address(0),
            "DAOCommittee: deployed candidateContract is zero"
        );

        candidateInfos[_layer2] = CandidateInfo({
            candidateContract: candidateContract,
            memberJoinedTime: 0,
            indexMembers: 0,
            rewardPeriod: 0,
            claimedTimestamp: 0
        });

        candidates.push(_layer2);
       
        emit OperatorRegistered(_layer2, candidateContract, _memo);
    }

    function fillMemberSlot() internal {
        for (uint256 i = members.length; i < maxMember; i++) {
            members.push(address(0));
        }
    }

    function _decodeAgendaData(bytes calldata input)
        internal
        view
        returns (AgendaCreatingData memory data)
    {
        (data.target, data.noticePeriodSeconds, data.votingPeriodSeconds, data.functionBytecode) = 
            abi.decode(input, (address[], uint256, uint256, bytes[]));
    }

    function payCreatingAgendaFee(address _creator) internal {
        uint256 fee = agendaManager.createAgendaFees();

        require(IERC20(ton).transferFrom(_creator, address(this), fee), "DAOCommitteeStore: failed to transfer ton from creator");
        require(IERC20(ton).transfer(address(1), fee), "DAOCommitteeStore: failed to burn");
    }
   
    function _createAgenda(
        address _creator,
        address[] memory _targets,
        uint256 _noticePeriodSeconds,
        uint256 _votingPeriodSeconds,
        bytes[] memory _functionBytecodes
    )
        internal
        validAgendaManager
        returns (uint256)
    {
        // pay to create agenda, burn ton.
        payCreatingAgendaFee(_creator);

        uint256 agendaID = agendaManager.newAgenda(
            _targets,
            _noticePeriodSeconds,
            _votingPeriodSeconds,
            0,
            _functionBytecodes
        );
          
        emit AgendaCreated(
            _creator,
            agendaID,
            _targets,
            _noticePeriodSeconds,
            _votingPeriodSeconds
        );

        return agendaID;
    }

    function isCandidate(address _candidate) public view returns (bool) {
        CandidateInfo storage info = candidateInfos[_candidate];

        if (info.candidateContract == address(0)) {
            return false;
        }

        bool supportIsCandidateContract = ERC165Checker.supportsInterface(
            info.candidateContract,
            ICandidate(info.candidateContract).isCandidateContract.selector
        );

        if (supportIsCandidateContract == false) {
            return false;
        }

        return ICandidate(info.candidateContract).isCandidateContract();
    }
    
    function totalSupplyOnCandidate(
        address _candidate
    )
        public
        view
        returns (uint256 totalsupply)
    {
        address candidateContract = candidateContract(_candidate);
        return totalSupplyOnCandidateContract(candidateContract);
    }

    function balanceOfOnCandidate(
        address _candidate,
        address _account
    )
        public
        view
        returns (uint256 amount)
    {
        address candidateContract = candidateContract(_candidate);
        return balanceOfOnCandidateContract(candidateContract, _account);
    }
    
    function totalSupplyOnCandidateContract(
        address _candidateContract
    )
        public
        view
        returns (uint256 totalsupply)
    {
        require(_candidateContract != address(0), "This account is not a candidate");

        address coinage = seigManager.coinages(_candidateContract);
        require(coinage != address(0), "DAOCommittee: coinage is zero");
        return IERC20(coinage).totalSupply();
    }

    function balanceOfOnCandidateContract(
        address _candidateContract,
        address _account
    )
        public
        view
        returns (uint256 amount)
    {
        require(_candidateContract != address(0), "This account is not a candidate");

        address coinage = seigManager.coinages(_candidateContract);
        require(coinage != address(0), "DAOCommittee: coinage is zero");
        return IERC20(coinage).balanceOf(_account);
    }

    function candidatesLength() public view returns (uint256) {
        return candidates.length;
    }

    function isExistCandidate(address _candidate) public view returns (bool isExist) {
        return candidateInfos[_candidate].candidateContract != address(0);
    }

    function getClaimableActivityReward(address _candidate) public view returns (uint256) {
        CandidateInfo storage info = candidateInfos[_candidate];
        uint256 period = info.rewardPeriod;

        if (info.memberJoinedTime > 0) {
            if (info.memberJoinedTime > info.claimedTimestamp) {
                period = period.add(block.timestamp.sub(info.memberJoinedTime));
            } else {
                period = period.add(block.timestamp.sub(info.claimedTimestamp));
            }
        }

        return period.mul(activityRewardPerSecond);
    }
}
