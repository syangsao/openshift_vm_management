# Networking and storage for VMs

## Networking: there is no static IP field on a VM

This trips people up. The `interfaces` schema in OCP 4.22 exposes:

```
bridge  dhcpOptions  macAddress  macvtap  masquerade  model
name    passt        pciAddress  ports    slirp       sriov  state
```

There is **no** `ipAddress` / `ipAddresses`. You cannot set a static IP in the VM
spec. Confirm on your own cluster:

```bash
oc explain virtualmachine.spec.template.spec.domain.devices.interfaces --recursive
```

So a VM gets its address one of four ways:

| Approach | How | When to use |
| --- | --- | --- |
| **Pod network** | `masquerade: {}` — address comes from the cluster pod CIDR | Default. Outbound works, inbound needs a `Service`. |
| **Multus + IPAM** | NAD allocates from a pool (`host-local`) | You need VMs on a specific subnet, cluster-managed. |
| **Multus + external DHCP** | NAD with `ipam: {}`, `topology: localnet` | VM is a first-class citizen on the physical LAN. |
| **Static inside the guest** | cloud-init / sysprep | Always available, full control. |

### Pod network (default)

```yaml
      interfaces:
        - name: podnet
          masquerade: {}
      networks:
        - name: podnet
          pod: {}
```

The VM is NAT'd behind the node. Reach it with a Service:

```bash
virtctl expose vm <VM_NAME> --name <VM_NAME>-ssh --type ClusterIP --port 22
oc get svc <VM_NAME>-ssh
```

### Multus — specific subnet

Attach a `NetworkAttachmentDefinition`. Find them with:

```bash
oc get network-attachment-definitions -A
oc get network-attachment-definition <NAD_NAME> -n <NAD_NAMESPACE> -o jsonpath='{.spec.config}' | python3 -m json.tool
```

Two common NAD shapes:

**a) OVN-Kubernetes localnet** — bridges a VLAN straight to the physical network;
addresses come from whatever serves DHCP on that VLAN.

```json
{
  "cniVersion": "0.3.1",
  "name": "vlan-60",
  "type": "ovn-k8s-cni-overlay",
  "topology": "localnet",
  "netAttachDefName": "default/vlan-60",
  "mtu": 1500,
  "ipam": {}
}
```

**b) macvlan with host-local IPAM** — the cluster allocates the address itself.

```json
{
  "cniVersion": "0.3.1",
  "name": "vlan-60",
  "plugins": [
    {
      "type": "macvlan",
      "master": "eth1",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "subnet": "192.0.2.0/24",
        "rangeStart": "192.0.2.10",
        "rangeEnd": "192.0.2.250"
      }
    }
  ]
}
```

Attach it:

```yaml
      interfaces:
        - name: vlan60
          bridge: {}
          model: virtio
      networks:
        - name: vlan60
          multus:
            networkName: <NAD_NAMESPACE>/<NAD_NAME>
```

### Pinning a specific MAC address

```yaml
      interfaces:
        - name: vlan60
          bridge: {}
          macAddress: "02:00:00:00:00:60"
```

If `kubemacpool` is enabled, leave `macAddress` empty and it will allocate a
unique one (it injects a `kubemacpool.io/transaction-timestamp` annotation).

### Static IP via cloud-init

```yaml
      volumes:
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              write_files:
                - path: /etc/NetworkManager/system-connections/vlan60.nmconnection
                  permissions: '0600'
                  content: |
                    [connection]
                    id=vlan60
                    type=ethernet
                    interface-name=enp2s0
                    [ipv4]
                    method=manual
                    addresses=192.0.2.50/24
                    gateway=192.0.2.1
                    dns=192.0.2.1;
              runcmd:
                - nmcli connection reload
                - nmcli connection up vlan60
```

### DHCP tuning

The interface spec exposes DHCP options for the pod network:

```yaml
      interfaces:
        - name: podnet
          masquerade: {}
          dhcpOptions:
            ntpServers: ["192.0.2.1"]
            bootFileName: bootx64.efi
```

---

## Storage

Every VM disk is a PVC (or a `DataVolume` that produces one). Check what your
storage can do before designing VMs:

```bash
oc get storageclass
oc get storageprofile -o custom-columns=\
NAME:.metadata.name,\
CLONE:.status.cloneStrategy,\
SNAPSHOTCLASS:.status.snapshotClass
```

`StorageProfile` tells you the CDI-discovered capabilities: clone strategy,
snapshot support, and default access/volume modes.

### Volume mode and access mode

| Requirement | Setting |
| --- | --- |
| Live migration | `ReadWriteMany` access mode |
| Best performance | `Block` volume mode |
| Snapshots | a `snapshotClass` in the `StorageProfile` |

`ReadWriteOnce` disks **cannot** live migrate. Set `evictionStrategy: None` on
those VMs so node reboots power them off instead of hanging the drain.

### OS disk + data disks

```yaml
spec:
  dataVolumeTemplates:
    - metadata: {name: <VM_NAME>-root}          # OS disk
      spec:
        sourceRef:
          kind: DataSource
          name: rhel9
          namespace: openshift-virtualization-os-images
        storage:
          resources: {requests: {storage: 30Gi}}
          storageClassName: <STORAGE_CLASS>
    - metadata: {name: <VM_NAME>-data}          # data disk, empty
      spec:
        source: {blank: {}}
        storage:
          resources: {requests: {storage: 100Gi}}
          storageClassName: <STORAGE_CLASS>
  template:
    spec:
      volumes:
        - name: root
          dataVolume: {name: <VM_NAME>-root}
        - name: data
          dataVolume: {name: <VM_NAME>-data}
      domain:
        devices:
          disks:
            - {name: root, disk: {bus: virtio}, bootOrder: 1}
            - {name: data, disk: {bus: virtio}}
```

DataVolumes in `dataVolumeTemplates` are **owned by the VM** and are garbage
collected with it. See [`04-delete/`](../04-delete/).

### Disk bus types

| Bus | Notes |
| --- | --- |
| `virtio` | Best performance. Needs virtio drivers (built in for Linux, install for Windows). |
| `sata` | Windows install media / driver ISOs. |
| `scsi` | Windows data disks, up to 200 attached. |

### Expanding a disk

The PVC must allow expansion (`allowVolumeExpansion: true` on the storage class),
then:

```bash
oc patch pvc <VM_NAME>-data -n <NAMESPACE> --type merge \
  -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'

# The filesystem does not grow by itself - resize inside the guest:
virtctl console <VM_NAME>
# growpart /dev/vda 2 && xfs_growfs /
```

File systems **cannot** be shrunk. Decreasing a disk means creating a smaller
one and copying the data.
