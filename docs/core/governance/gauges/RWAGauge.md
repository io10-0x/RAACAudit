# RWA Gauge

## Overview

The RWAGauge contract implements a monthly gauge mechanism for Real World Asset (RWA) yield direction with time-weighted voting.  
It extends [BaseGauge](core/governance/gauges/BaseGauge.md) to provide specialized functionality for managing RWA-specific voting periods, reward distribution, and boost calculations.

## Access Control

Inherited from [BaseGauge.md](/core/governance/gauges/BaseGauge.md).

## Key Functions

| Name | Description | Access | Parameters |
|------|-------------|---------|------------|
| `voteYieldDirection` | Vote on yield direction with voting power. Wrapper around BaseGauge's voteDirection | External | `direction`: Yield direction in basis points (0-10000) |
| `setMonthlyEmission` | Sets monthly emission cap | Controller | `emission`: New emission amount |
| `getPeriodDuration` | Gets the duration of a period | View | None |
| `getTotalWeight` | Gets total weight of the gauge | View | None |

## Implementation Details

- Uses fixed monthly periods via configurable periods in BaseGauge (as constant DAYS on constructor)
- Enforces a maximum weekly emission (set as 500k RAAC)
- Voting focused on emission direction

## Events

| Event Name | Description | Parameters |
|------------|-------------|------------|
| EmissionUpdated | When weekly emission changes | `emission`: New rate |

## Error Conditions

| Name | Description |
|------|-------------|
| InvalidWeight | Weight exceeds allowed precision (10000) |
| NoVotingPower | User has no veToken balance |
| RewardCapExceeded | Reward amount exceeds monthly cap |
| InsufficientRewardBalance | Contract has insufficient rewards |
| PeriodNotElapsed | Current period hasn't ended |
| ZeroRewardRate | Calculated reward rate is zero |

## Usage Notes

- Inherits all core functionality from BaseGauge
- Requires veRAAC for voting power
- Monthly periods for emissions (BaseGauge period configurability)
- Minimum claim interval is 1 day

### BaseGauge inheritance notes

- Time-weighted vote tracking for RAAC token emissions directionality voting
- Staking affects reward distribution
- Emergency pause available
- Emission caps enforced
- Boost parameters configurable

### Test Setup Requirements

1. Token Setup:
   - Deploy mock veRAACToken for voting power
   - Deploy mock rewardToken for distributions
   - Mint initial token supplies

2. Contract Setup:
   - Deploy GaugeController
   - Deploy RWAGauge with controller and reward token
   - Set initial weights and boost parameters
   - Grant necessary roles

3. Time Management:
   - Align to monthly period boundaries
   - Use time helpers for period transitions

## Dependencies

Inherits from:

- BaseGauge contract (see [BaseGauge.md](/core/governance/gauges/BaseGauge.md) for full details)