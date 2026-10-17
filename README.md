Use case:
New Windows OS UEFI installation with 2nd drive for mirroring.
Main drive is drive 0, mirror drive is drive 1.

C:\> .\Set-BootMirror.ps1 -TargetDisk 1

This will:
1. Detect the OS drive (most likely disk 0).
2. Erase the target disk (it will confirm before it does... make sure you have chosen the correct disk).
3. Re-create the source partitions onto the target disk, same size, same order.
4. Convert both disks to dynamic and mirror the OS data partition.
6. The BCD initially written to the mirror does not work. Copy the BCD from the source drive and repoint the boot/recovery/memdiag to the target disk.
7. Copy the recovery and EFI partitions.

It is recommended to re-run steps 6 and 7 once every year or so, as Windows Updates can update the RE and/or EFI partition files.
Refreshing these two partitions can done by running the following:

C:\> .\Set-BootMirror.ps1 -TargetDisk 1 -Phase SyncBoot
