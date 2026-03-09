import sys, time
def run():
    print("starting")
    for line in sys.stdin:
        print("got:", line.strip())
        sys.stdout.flush()

if __name__ == '__main__':
    run()
