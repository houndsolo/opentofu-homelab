# Build the project yourself

1. Read one root's main.tf, its variable schema, and its inventory values.
2. Run init, validate, and plan. Check the output values.
3. Add the provider you need and configure its credentials.
4. Replace one module's output-only example with one real resource.
5. Add the next resource after you understand the first plan.

Extend the inventory with VRFs, VNIs, images, templates, or containers as needed.
Keep static topology in inventory. Let each root own its resources and state.
VM roots own machine lifecycle; leaf and spine roots own device configuration.
The examples use a single Proxmox cluster and demonstration addresses.
