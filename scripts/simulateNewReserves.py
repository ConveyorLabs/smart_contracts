import math
from eth_abi import encode
import sys
def main(args):
    
    alphaX=int(args[1])
    reserveIn = int(args[2])
    reserveOut = int(args[3])

    reserveA= reserveIn+alphaX

    reserveB = math.ceil((reserveIn*reserveOut)/(reserveA))

    enc = encode(['uint256'], [int(reserveB)])
    print("0x" + enc.hex())

if __name__ == '__main__':
    args = sys.argv
    main(args)