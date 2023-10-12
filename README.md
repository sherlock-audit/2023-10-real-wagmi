
# Real Wagmi #2 contest details

- Join [Sherlock Discord](https://discord.gg/MABEWyASkp)
- Submit findings using the issue page in your private contest repo (label issues as med or high)
- [Read for more details](https://docs.sherlock.xyz/audits/watsons)

# Q&A

### Q: On what chains are the smart contracts going to be deployed?
Mainnet, KavaEVM,Arbitrum, polygon, zkera, optimism,fantom opera, avalanche,base,linea,bs
___

### Q: Which ERC20 tokens do you expect will interact with the smart contracts? 
any
___

### Q: Which ERC721 tokens do you expect will interact with the smart contracts? 
uni-v3 approve only
___

### Q: Which ERC777 tokens do you expect will interact with the smart contracts? 
none
___

### Q: Are there any FEE-ON-TRANSFER tokens interacting with the smart contracts?

no
___

### Q: Are there any REBASING tokens interacting with the smart contracts?

no
___

### Q: Are the admins of the protocols your contracts integrate with (if any) TRUSTED or RESTRICTED?
Trusted
___

### Q: Is the admin/owner of the protocol/contracts TRUSTED or RESTRICTED?
Trusted
___

### Q: Are there any additional protocol roles? If yes, please explain in detail:
Daily rate operator has the ability to set interest rates for daily rates for the pool 
___

### Q: Is the code/contract expected to comply with any EIPs? Are there specific assumptions around adhering to those EIPs that Watsons should be aware of?
not specifially 
___

### Q: Please list any known issues/acceptable risks that should not result in a valid finding.
No known risk or issues
___

### Q: Please provide links to previous audits (if any).
n/a
___

### Q: Are there any off-chain mechanisms or off-chain procedures for the protocol (keeper bots, input validation expectations, etc)?
Offchain mechanisms are: 

1. Operator which will set daily rate in accordance with offchain formula which is taking volatility of the pair account when finding applicable desired rate. 

2. Bots will parse and save approved nfts calculate liquidity and provide info on them for the frontend to select which particular nfts to dismantle
___

### Q: In case of external protocol integrations, are the risks of external contracts pausing or executing an emergency withdrawal acceptable? If not, Watsons will submit issues related to these situations that can harm your protocol's functionality.
none
___

### Q: Do you expect to use any of the following tokens with non-standard behaviour with the smart contracts?
Whatever uniswap v3 supports for their pools can interact with our contracts 
___

### Q: Add links to relevant protocol resources
n/a 
___



# Audit scope