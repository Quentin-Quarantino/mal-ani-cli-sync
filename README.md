# ani-track
ani-track is a shell script to update animes on myanimelist from the [ani-cli](https://github.com/pystardust/ani-cli/tree/master) watch history

**The script is not fully developed. use at your own risk**

## Install
1. Clone the repository:
    ```bash
    git clone https://github.com/Quentin-Quarantino/ani-track.git
    ```

2. Change into the directory:
    ```bash
    cd ani-track
    ```

3. Make the script executable:
    ```bash
    chmod +x ani-track-v2.sh
    ```

4. Move the script to ~/bin:
    ```bash
    [ -d ~/bin ] || mkdir ~/bin
    mv ani-track-v2.sh ~/bin/
    ```

5. Optionally, if ~/bin is not in your PATH, add it to your .bashrc or .bash_profile:
    ```bash
    echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
    ```

6. Run the script to create the secrets file
    ```bash
    ani-track-v2.sh
    add your api client id and the secret in the /home/user/.local/state/ani-track/.secrets and re-run the script
    ```

7. Go on myanimelist and create a API client
    User > Settings > API > Create ID

    Important are these two points
     - API Type: Web
     - App Redirect URL: http://localhost:8080/index.html

8. Copy the Client ID and Client Sectret and fill the variables "client_id" and "client_secret" it in the .secrets

9. Optionally: if you use a diffrent web browser then firefox change the variable "web_browser" in ~.local/state/ani-track/ani-track.conf to the web browser of youre choice

10. run the script and authenticate in the web browser.


## TODO
- [x] restore MAL watchlist from backup
- [x] help page
- [x] option parsing
- [ ] better history
- [ ] update MAL score and watch status of new animes
- [ ] change script name
- [x] update script function
- [ ] readme.md, dev and protected main/master branch
- [x] anime recomendations based on watchlist
- [ ] get seasonal animes
- [ ] get {pre-}sequel of animes that are in watchlist
- [x] if a anime is completed set the status ether
- [x] custom config


how to create a MAL API OAuth 2.0 client ID and secret: [MAL Blog Post](https://myanimelist.net/blog.php?eid=835707)
