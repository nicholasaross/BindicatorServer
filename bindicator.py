"""Scrape bin collection dates from Reigate & Banstead council website."""

from datetime import datetime

from bs4 import BeautifulSoup
from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait

UPRN = "200001920678"
BASE_URL = "https://my.reigate-banstead.gov.uk/en/service/Bins_and_recycling___collections_calendar"


def get_collections(uprn: str = UPRN) -> dict[str, list[str]]:
    """Return upcoming bin collections as {ISO date: [collection types]}."""
    url = f"{BASE_URL}?uprn={uprn}"

    options = webdriver.ChromeOptions()
    options.add_argument("--headless=new")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")

    driver = webdriver.Chrome(options=options)
    try:
        driver.get(url)
        wait = WebDriverWait(driver, 30)

        # Switch into the govService iframe
        iframe = wait.until(
            EC.presence_of_element_located((By.ID, "fillform-frame-1"))
        )
        driver.switch_to.frame(iframe)

        # Wait for collection data to render (content appears in the second
        # span[data-name="html2"] element after an async fetch)
        def _data_ready(d):
            elems = d.find_elements(By.CSS_SELECTOR, 'span[data-name="html2"]')
            for el in elems:
                if el.get_attribute("innerHTML").strip():
                    return el
            return False

        elem = WebDriverWait(driver, 60).until(_data_ready)
        html = elem.get_attribute("innerHTML")
    finally:
        driver.quit()

    soup = BeautifulSoup(html, "html.parser")
    collections: dict[str, list[str]] = {}

    for h3 in soup.find_all("h3"):
        raw_date = h3.get_text(strip=True)
        try:
            dt = datetime.strptime(raw_date, "%A %d %B %Y")
        except ValueError:
            continue
        iso_date = dt.strftime("%Y-%m-%d")

        # h3 is inside a wrapper div; the <ul> is in a sibling div.
        # Go up to the grandparent div that contains both.
        parent_div = h3.find_parent("div").find_parent("div")
        types = [
            span.get_text(strip=True)
            for li in parent_div.find_all("li")
            for span in li.find_all("span")
            if span.get_text(strip=True)
        ]
        collections[iso_date] = types

    return collections


if __name__ == "__main__":
    schedule = get_collections()
    for date, types in sorted(schedule.items()):
        print(f"{date}: {', '.join(types)}")
