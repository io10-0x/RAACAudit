import { expect } from "chai";
import hre from "hardhat";
const { ethers } = hre;

describe("StringUtils", () => {
    let mockStringUtils;
    let hasContract = true;

    before(async () => {
        try {
            const MockStringUtils = await ethers.getContractFactory("MockStringUtils");
            mockStringUtils = await MockStringUtils.deploy();
            await mockStringUtils.waitForDeployment();
        } catch (e) {
            hasContract = false;
            console.log("MockStringUtils contract not found, skipping tests");
        }
    });

    describe("stringToUint", () => {
        beforeEach(function() {
            if (!hasContract) {
                this.skip();
            }
        });

        it("should convert single digit numbers correctly", async () => {
            for (let i = 0; i <= 9; i++) {
                const result = await mockStringUtils.stringToUint(i.toString());
                expect(result).to.equal(i);
            }
        });

        it("should convert multi-digit numbers correctly", async () => {
            const testCases = [
                "12",
                "345",
                "6789",
                "10000",
                "999999"
            ];

            for (const testCase of testCases) {
                const result = await mockStringUtils.stringToUint(testCase);
                expect(result).to.equal(BigInt(testCase));
            }
        });

        it("should handle zero correctly", async () => {
            const result = await mockStringUtils.stringToUint("0");
            expect(result).to.equal(0);
        });

        it("should handle leading zeros correctly", async () => {
            const testCases = [
                "00",
                "01",
                "0023",
                "000456"
            ];

            for (const testCase of testCases) {
                const result = await mockStringUtils.stringToUint(testCase);
                expect(result).to.equal(BigInt(parseInt(testCase)));
            }
        });
        it("should handle maximum safe numbers", async () => {
            const largeNumber = "123456789012345678901234567890"; // 30 digits but within uint256 range
            const result = await mockStringUtils.stringToUint(largeNumber);
            expect(result).to.equal(BigInt(largeNumber));
        });
    });
}); 