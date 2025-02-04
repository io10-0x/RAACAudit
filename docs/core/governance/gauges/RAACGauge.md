# RAACGauge

## Overview

The RAACGauge is a contract that manages weekly RAAC emissions and staking with direction voting capabilities.  
It extends [BaseGauge.md](/core/governance/gauges/BaseGauge.md).

## Access Control

Inherited from [BaseGauge.md](/core/governance/gauges/BaseGauge.md).

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| WEEK | 7 days | Fixed weekly period duration |
| MAX_WEEKLY_EMISSION | 500000e18 | Maximum weekly emission cap |

## Key Functions

| Function Name | Description | Access | Parameters | Returns |
|---------------|-------------|---------|------------|---------|
| voteEmissionDirection | Wrapper around BaseGauge's voteDirection | External | `direction`: Vote direction (0-10000) | None |
| setWeeklyEmission | Updates the weekly emission rate | Controller | `emission`: New emission rate | None |

## Implementation Details

- Uses fixed 7 day periods via configurable periods in BaseGauge (as constant DAYS on constructor)
- Enforces a maximum weekly emission (set as 500k RAAC)
- Voting focused on emission direction

## Events

| Event Name | Description | Parameters |
|------------|-------------|------------|
| EmissionUpdated | When weekly emission changes | `emission`: New rate |

## Usage Notes

- Inherits all core functionality from BaseGauge
- Requires veRAAC for voting power
- Weekly periods for emissions (BaseGauge for period configurability)

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
   - Deploy RAACGauge with controller and reward token
   - Set initial weights and boost parameters
   - Grant necessary roles

3. Time Management:
   - Align to monthly period boundaries
   - Use time helpers for period transitions

## Dependencies

Inherits from:

- BaseGauge contract (see [BaseGauge.md](/core/governance/gauges/BaseGauge.md) for full details)